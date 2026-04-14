# 容器运行时满载压力测试总结：Pod 密度与 Overhead 配置指南

**测试日期：** 2026-04-14  
**环境：** Amazon EKS 1.34，嵌套虚拟化（EC2 bare-metal-equivalent 上的 KVM）  
**Kata Operator：** v0.22.2 | **Guest Kernel：** 6.18.12 | **Host Kernel：** 6.12.68  
**gVisor：** runsc release-20260406.0

---

## 1. 测试概要

在两种机型（m8i.2xlarge / m8i.4xlarge）上，分别使用 kata-qemu、kata-clh 和 gVisor (runsc) 运行时，逐个部署满载 Pod（stress-ng CPU 95% + 内存 vm-keep），测量单节点最大稳定 Pod 数。

### 工作负载规格（每 Pod，Guaranteed QoS）

| 容器 | CPU | 内存 | stress-ng 参数 |
|------|-----|------|---------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |
| **容器合计** | **450m** | **2048 MiB** | **1750 MiB vm-bytes** |

---

## 2. 核心结果

### 2.1 最大稳定 Pod 数

| 机型 | vCPU | 内存 | kata-qemu | kata-clh | gVisor | CLH vs QEMU | gVisor vs QEMU |
|------|------|------|-----------|----------|--------|------------|---------------|
| m8i.2xlarge | 8 | 32 GiB | **7** | **13** | **14** | +86% | **+100%** |
| m8i.4xlarge | 16 | 64 GiB | **14** | **24** | — | +71% | — |

### 2.2 失败模式对比

| 维度 | kata-qemu | kata-clh | gVisor |
|------|-----------|----------|--------|
| **2xlarge 失败** | Pod 8：4 次 restart | Pod 14：调度器拒绝 | Pod 15：Failed（内存耗尽） |
| **4xlarge 失败** | Pod 15：4 次 restart | 无失败，24 Pod 时 90% 内存 | — |
| **失败根因** | VMExit 争抢 + nested page walk | 达到调度器上限 | 达到调度器上限 |
| **理论达成率** | 56-58% | 96-100% | **100%** |

---

## 3. 理论值 vs 实际值差距分析

### 3.1 数据对比

| 机型 | 运行时 | 调度器理论上限 | 实际稳定数 | 利用率 | 差距 |
|------|--------|-------------|-----------|--------|------|
| m8i.2xlarge | gVisor | 14 | 14 | **100%** | **0 pods** |
| m8i.2xlarge | kata-clh | 13 | 13 | **100%** | **0 pods** |
| m8i.2xlarge | kata-qemu | 12 | 7 | 58% | **-5 pods (42%)** |
| m8i.4xlarge | kata-clh | 25 | 24 | 96% | **-1 pod (4%)** |
| m8i.4xlarge | kata-qemu | 25 | 14 | 56% | **-11 pods (44%)** |

> **理论上限计算方式**：`floor((节点可调度内存 - 系统 Pod 请求) / (容器 request + Pod Overhead))`

### 3.2 差距根因

#### kata-qemu：嵌套虚拟化下 VMExit 与内存虚拟化开销（主因）

```
失败时节点资源利用：
  m8i.2xlarge: CPU 36%, 内存 53% — 大量资源闲置
  m8i.4xlarge: CPU 43%, 内存 54% — 大量资源闲置
```

QEMU 在嵌套虚拟化下的瓶颈**不是内存或 CPU 的绝对不足**，而是多层虚拟化带来的系统开销叠加：

1. **频繁 VMExit（核心瓶颈）**：QEMU 模拟完整 PC 硬件（ACPI、PCI、USB 等），每个设备的 MMIO 操作都需要 VMExit。嵌套虚拟化下 VMExit 路径为 L2→L1→L0，每次 VMExit 消耗数百到数千 CPU cycles。VM 数量增多时，VMExit 频率线性叠加，hypervisor 的 CPU 时间被大量消耗在 exit handling 上
2. **Nested page table walk 放大**：嵌套虚拟化下地址翻译为两级 EPT walk（GVA→GPA→HPA），单次 page table walk 最多需要 24 次内存访问（4 级 × 2 层 EPT × 3 次访问）。VM 数量增多时，TLB 容量被多个 VM 分摊，TLB miss rate 上升，nested page walk 频率进一步增加
3. **vCPU 调度争抢**：每个 kata VM 默认 5 个 vCPU，满载下所有 vCPU 都在活跃运行。L1 hypervisor 需要调度大量 vCPU 到有限的物理 CPU 上，调度延迟和上下文切换开销随 VM 数增长
4. **VM 启动时的资源尖峰**：新 VM 启动需要大量 page fault handling（guest 内存首次触碰）+ 设备初始化 VMExit，与已有 VM 的活跃负载产生严重 CPU 争抢

**密度与 vCPU 的近似线性关系**：2xlarge(8 vCPU)→7 pods，4xlarge(16 vCPU)→14 pods，精确 2 倍。这表明瓶颈在 CPU 侧（VMExit handling + vCPU scheduling），但也可能受 K8s scheduler admission、VM startup burst 等因素共同影响，不能单凭此断言瓶颈只在 CPU/EPT。

#### kata-clh：几乎无差距

CLH 接近或达到调度器理论上限（100% / 96%），原因：

1. **极简设备模型，VMExit 大幅减少**：Cloud Hypervisor 仅实现 virtio 设备，无 ACPI/PCI/USB 等传统设备模拟。业界研究表明设备模拟开销可占 QEMU 总开销的 50-70%，CLH 直接消除了这部分
2. **更低的 hypervisor 参与度**：virtio 使用 shared memory + eventfd 通知机制，大部分数据传输无需 VMExit，减少了嵌套虚拟化下的 L2→L1→L0 切换频率
3. **更小的 VMM 进程开销**：CLH 进程 RSS 比 QEMU 小 ~40 MiB（167 MiB vs 207 MiB），减少了 cache/NUMA/内存压力（但这不是决定性因素）
4. **更低的 Pod Overhead**：200 MiB vs 250 MiB，每 Pod 节省 50 MiB，调度器允许更多 Pod

---

## 4. 推荐 Pod Overhead 配置

### 4.1 嵌套虚拟化环境（EKS on .metal 实例）

```yaml
# kata-qemu — 嵌套虚拟化
overhead:
  podFixed:
    cpu: 250m
    memory: 350Mi
```

| 机型 | 调度器允许 Pod 数 | 预期稳定数 | 安全余量 |
|------|------------------|-----------|---------|
| m8i.2xlarge | floor(29751/2398) = 12 | ~7 | 5 pods |
| m8i.4xlarge | floor(58417/2398) = 24 | ~14 | 10 pods |

> ⚠️ kata-qemu 在嵌套虚拟化下，调度器预留与实际稳定数有较大差距。Overhead 机制只能增加调度器的内存/CPU 预留，**无法解决 VMExit 争抢和 nested page walk 开销**。这是 Pod Overhead 模型的固有局限 — 它假设开销可以用固定的 CPU/内存量表示，但嵌套虚拟化的开销是随 VM 数量非线性增长的系统级开销。

```yaml
# kata-clh — 嵌套虚拟化
overhead:
  podFixed:
    cpu: 100m
    memory: 200Mi
```

| 机型 | 调度器允许 Pod 数 | 预期稳定数 | 安全余量 |
|------|------------------|-----------|---------|
| m8i.2xlarge | floor(29751/2248) = 13 | 13 | 0 pods（调度器即瓶颈） |
| m8i.4xlarge | floor(58417/2248) = 25 | 24 | 1 pod |

> ✅ kata-clh 的 overhead 精确匹配实际开销，调度器理论值即为实际可达值。

### 4.2 裸金属环境（无嵌套虚拟化）

```yaml
# kata-qemu — 裸金属
overhead:
  podFixed:
    cpu: 100m
    memory: 250Mi    # 实测 207 MiB + 20% 余量

# kata-clh — 裸金属
overhead:
  podFixed:
    cpu: 100m
    memory: 200Mi    # 实测 167 MiB + 20% 余量
```

裸金属消除了嵌套虚拟化的额外 VMExit 路径和 nested page walk 开销，kata-qemu 的密度瓶颈将大幅缓解，预期可达到或接近调度器理论上限。

---

## 5. 运行时选择建议

### 5.1 综合对比

| 维度 | kata-qemu | kata-clh | gVisor | 胜出 |
|------|-----------|----------|--------|------|
| **满载 Pod 密度（2xlarge）** | 7 | 13 | **14** | **gVisor** |
| **调度器利用率** | 56-58% | 96-100% | **100%** | **gVisor** |
| **隔离强度** | **硬件 VM** | **硬件 VM** | 用户态内核 | **Kata** |
| **VM 进程开销** | 207 MiB | 167 MiB | **0** | **gVisor** |
| **Pod Overhead** | 250 MiB | 200 MiB | **0** | **gVisor** |
| **失败模式** | VM restart | 调度器拒绝 | 调度器拒绝 | CLH/gVisor |
| **嵌套虚拟化兼容性** | 差 | 好 | **不需要** | **gVisor** |
| **超卖稳定性** | 稳定 | 高负载 crash | 待测 | QEMU |
| **网络吞吐** | 32.2 Gbps | 16.6 Gbps | 待测 | QEMU |
| **syscall 兼容性** | **完整** | **完整** | 部分 | **Kata** |
| **生态成熟度** | 成熟 | 较新 | 成熟（GKE 默认） | QEMU/gVisor |

### 5.2 场景推荐

| 场景 | 推荐运行时 | 理由 |
|------|-----------|------|
| **最大 Pod 密度 + 无需 VM 隔离** | gVisor | 零 overhead，密度最高，不需嵌套虚拟化 |
| **嵌套虚拟化 + 高密度 + VM 隔离** | kata-clh | 密度比 QEMU 高 71-86%，达到调度器上限 |
| **嵌套虚拟化 + 网络密集** | kata-qemu | 网络吞吐 32.2 Gbps vs CLH 16.6 Gbps |
| **裸金属部署 + VM 隔离** | kata-qemu | 嵌套开销消失后 QEMU 密度接近 CLH，生态更成熟 |
| **内存超卖场景** | kata-qemu | CLH 在超卖高负载下有 crash 风险 |
| **GKE 环境** | gVisor | GKE 原生支持，零运维成本 |

---

## 6. 关键数字速查

| 指标 | kata-qemu | kata-clh |
|------|-----------|----------|
| 每 Pod stress-ng CPU | ~452m | ~452m |
| 每 Pod stress-ng 内存 | ~1810 MiB | ~1810 MiB |
| 每 Pod cAdvisor 内存增量 | ~2161 MiB | ~2130 MiB |
| VM 进程开销（Test 7/9） | 207 MiB | 167 MiB |
| VM 启动时间 | 6-9s | 7s |
| 推荐 overhead（嵌套） | cpu=250m, mem=350Mi | cpu=100m, mem=200Mi |
| 推荐 overhead（裸金属） | cpu=100m, mem=250Mi | cpu=100m, mem=200Mi |

---

## 7. 测试子目录

| 目录 | 运行时 | 机型 | 结果 |
|------|--------|------|------|
| [stress-2x-gvisor/](stress-2x-gvisor/) | gVisor (runsc) | m8i.2xlarge | **14 pods 稳定**，Pod 15 Failed |
| [stress-2x-clh/](stress-2x-clh/) | kata-clh | m8i.2xlarge | 13 pods 稳定，Pod 14 调度器拒绝 |
| [stress-2x-qemu/](stress-2x-qemu/) | kata-qemu | m8i.2xlarge | 7 pods 稳定，Pod 8 restart |
| [stress-4x-qemu/](stress-4x-qemu/) | kata-qemu | m8i.4xlarge | 14 pods 稳定，Pod 15 restart |
| [stress-4x-clh/](stress-4x-clh/) | kata-clh | m8i.4xlarge | 24 pods 稳定，节点内存 90% |

每个子目录包含：测试脚本、CSV 原始数据、执行日志、详细分析 README。
