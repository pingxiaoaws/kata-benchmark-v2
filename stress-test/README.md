# Kata Containers 满载压力测试总结：Pod 密度与 Overhead 配置指南

**测试日期：** 2026-04-14  
**环境：** Amazon EKS 1.34，嵌套虚拟化（EC2 bare-metal-equivalent 上的 KVM）  
**Kata Operator：** v0.22.2 | **Guest Kernel：** 6.18.12 | **Host Kernel：** 6.12.68

---

## 1. 测试概要

在两种机型（m8i.2xlarge / m8i.4xlarge）上，分别使用 kata-qemu 和 kata-clh 运行时，逐个部署满载 Pod（stress-ng CPU 95% + 内存 vm-keep），测量单节点最大稳定 Pod 数。

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

| 机型 | vCPU | 内存 | kata-qemu | kata-clh | CLH 优势 |
|------|------|------|-----------|----------|---------|
| m8i.2xlarge | 8 | 32 GiB | **7** | **13** | +86% |
| m8i.4xlarge | 16 | 64 GiB | **14** | **24** | +71% |

### 2.2 失败模式对比

| 维度 | kata-qemu | kata-clh |
|------|-----------|----------|
| **2xlarge 失败** | Pod 8：4 次 restart | Pod 14：调度器拒绝（内存不足） |
| **4xlarge 失败** | Pod 15：4 次 restart，stress 内存降至 877 MiB | 无失败，24 Pod 时节点内存 90% |
| **失败根因** | 嵌套虚拟化 EPT 争抢，VM 无法完整启动 | 达到调度器理论上限 |
| **影响范围** | 仅失败 Pod 自身 restart | 无影响 |

---

## 3. 理论值 vs 实际值差距分析

### 3.1 数据对比

| 机型 | 运行时 | 调度器理论上限 | 实际稳定数 | 利用率 | 差距 |
|------|--------|-------------|-----------|--------|------|
| m8i.2xlarge | kata-qemu | 12 | 7 | 58% | **-5 pods (42%)** |
| m8i.2xlarge | kata-clh | 13 | 13 | **100%** | **0 pods** |
| m8i.4xlarge | kata-qemu | 25 | 14 | 56% | **-11 pods (44%)** |
| m8i.4xlarge | kata-clh | 25 | 24 | 96% | **-1 pod (4%)** |

> **理论上限计算方式**：`floor((节点可调度内存 - 系统 Pod 请求) / (容器 request + Pod Overhead))`

### 3.2 差距根因

#### kata-qemu：嵌套虚拟化 EPT 争抢（主因）

```
失败时节点资源利用：
  m8i.2xlarge: CPU 36%, 内存 53% — 大量资源闲置
  m8i.4xlarge: CPU 43%, 内存 54% — 大量资源闲置
```

QEMU 在嵌套虚拟化下的瓶颈**不是内存或 CPU**，而是 L1 KVM hypervisor 的 EPT（Extended Page Table）影子页表管理：

1. **EPT 影子开销**：每个 QEMU VM 需要 L1 hypervisor 维护影子 EPT 页表，VM 数量越多，页表管理的 CPU 开销呈超线性增长
2. **VM 启动尖峰**：新 VM 启动时需要大量页表操作（guest 内存 fault-in、设备模拟），与已有 VM 的活跃页表管理产生严重争抢
3. **QEMU 设备模型复杂**：QEMU 模拟了完整的 PC 硬件（ACPI、PCI、USB 等），每个设备的 MMIO 操作都需要 VMExit → 加重 EPT 影子负担
4. **密度与 vCPU 线性相关**：2xlarge(8 vCPU) → 7 pods，4xlarge(16 vCPU) → 14 pods，精确 2 倍关系，证明瓶颈在 CPU 侧的 hypervisor 调度

#### kata-clh：几乎无差距

CLH 接近或达到调度器理论上限（100% / 96%），原因：

1. **精简设备模型**：Cloud Hypervisor 仅实现必要的 virtio 设备，无 ACPI/PCI/USB 等传统设备模拟，VMExit 频率大幅降低
2. **更小的 VMM 进程开销**：CLH 进程 RSS 比 QEMU 小 ~40 MiB（167 MiB vs 207 MiB），EPT 影子页表压力更小
3. **更低的 Pod Overhead**：200 MiB vs 250 MiB，每 Pod 节省 50 MiB，调度器允许更多 Pod
4. **更好的嵌套虚拟化兼容性**：简单的 VMM 架构使得 L1 hypervisor 的 EPT 管理更高效

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

> ⚠️ kata-qemu 在嵌套虚拟化下，调度器预留与实际稳定数有较大差距。Overhead 无法解决 EPT 争抢问题，只能通过调大 overhead 来间接限制密度。但这会浪费大量可调度资源。

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

裸金属消除了 EPT 影子页表开销，kata-qemu 的密度瓶颈将大幅缓解，预期可达到或接近调度器理论上限。

---

## 5. 运行时选择建议

### 5.1 综合对比

| 维度 | kata-qemu | kata-clh | 胜出 |
|------|-----------|----------|------|
| **满载 Pod 密度** | 7 / 14 | 13 / 24 | **CLH (+71~86%)** |
| **调度器利用率** | 56-58% | 96-100% | **CLH** |
| **VM 进程开销** | 207 MiB | 167 MiB | **CLH (-19%)** |
| **Pod Overhead** | 250 MiB | 200 MiB | **CLH (-20%)** |
| **失败模式** | VM restart | 调度器拒绝（优雅） | **CLH** |
| **嵌套虚拟化兼容性** | 差（EPT 争抢严重） | 好（精简设备模型） | **CLH** |
| **超卖稳定性** | 稳定 | 高负载 crash（Test 5b/10） | **QEMU** |
| **网络吞吐** | 32.2 Gbps (-50%) | 16.6 Gbps (-74%) | **QEMU** |
| **生态成熟度** | 成熟，社区活跃 | 较新，功能较少 | **QEMU** |

### 5.2 场景推荐

| 场景 | 推荐运行时 | 理由 |
|------|-----------|------|
| **嵌套虚拟化 + 高密度** | kata-clh | Pod 密度比 QEMU 高 71-86%，达到调度器上限 |
| **嵌套虚拟化 + 网络密集** | kata-qemu | 网络吞吐 32.2 Gbps vs CLH 16.6 Gbps |
| **裸金属部署** | kata-qemu | EPT 开销消失后 QEMU 密度接近 CLH，且生态更成熟 |
| **内存超卖场景** | kata-qemu | CLH 在超卖高负载下有 crash 风险 |
| **Guaranteed QoS + 最大密度** | kata-clh | 不超卖时 CLH 完全稳定，密度领先 |

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
| [stress-2x-qemu/](stress-2x-qemu/) | kata-qemu | m8i.2xlarge | 7 pods 稳定，Pod 8 restart |
| [stress-2x-clh/](stress-2x-clh/) | kata-clh | m8i.2xlarge | 13 pods 稳定，Pod 14 调度器拒绝 |
| [stress-4x-qemu/](stress-4x-qemu/) | kata-qemu | m8i.4xlarge | 14 pods 稳定，Pod 15 restart |
| [stress-4x-clh/](stress-4x-clh/) | kata-clh | m8i.4xlarge | 24 pods 稳定，节点内存 90% |

每个子目录包含：测试脚本、CSV 原始数据、执行日志、详细分析 README。
