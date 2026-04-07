# Kata Containers 嵌套虚拟化性能基准测试报告 v2

**日期**: 2026-04-03 ~ 2026-04-07  
**作者**: Ping Xiao / AI Assistant  
**集群**: test-s4, Amazon EKS 1.34, us-west-2  
**Operator**: OpenClaw Operator v0.22.2  
**运行时**: runc (containerd 2.1.5), kata-qemu, kata-clh  
**节点**: 9x m8i.4xlarge (16 vCPU, 64GB) + 1x r8i.2xlarge (8 vCPU, 64GB)  
**内核**: Host 6.12.68 (Amazon Linux 2023), Kata Guest 6.18.12  

---

## 目录

1. [测试目的](#1-测试目的)
2. [测试环境](#2-测试环境)
3. [Test 1: 单 Pod 冷启动](#3-test-1-单-pod-冷启动)
4. [Test 2: 节点饱和后启动](#4-test-2-节点饱和后启动)
5. [Test 3: 集群满载后启动](#5-test-3-集群满载后启动)
6. [Test 4: 运行时对比](#6-test-4-运行时对比)
7. [Test 5: 超卖稳定性](#7-test-5-超卖稳定性)
8. [Test 6: 运行时开销](#8-test-6-运行时开销)
9. [Test 7: 内存占用画像](#9-test-7-内存占用画像)
10. [综合结论](#10-综合结论)
11. [生产部署建议](#11-生产部署建议)

---

## 1. 测试目的

### 背景

Kata Containers 通过轻量级虚拟机（microVM）提供容器级别的 VM 隔离，是多租户 Kubernetes 集群安全隔离的关键技术。在 AWS EKS 环境中，Kata 运行在 EC2 实例（L1 VM）内部，形成 **L0 物理机 → L1 EC2 VM → L2 Kata microVM → L3 容器** 的三层嵌套虚拟化架构。

### 核心问题

1. **启动开销**: Kata microVM 的启动时间比标准 runc 容器慢多少？在不同负载条件下是否稳定？
2. **运行时开销**: 嵌套虚拟化对 CPU、内存、磁盘 I/O、网络的真实性能影响？
3. **内存占用**: 每个 Kata VM 的真实内存开销是多少？Kubernetes 能否准确监控？
4. **稳定性**: 在超卖（overcommit）场景下，Kata VM 是否稳定？
5. **kata-qemu vs kata-clh**: 两种 VMM（QEMU vs Cloud Hypervisor）的性能对比

### 测试维度

| 维度 | 测试项 | 关键指标 |
|------|--------|----------|
| 启动性能 | Test 1-3 | 冷/热启动时间、负载影响 |
| 稳态资源 | Test 4 | Idle CPU/Memory、功能验证 |
| 稳定性 | Test 5 | 200% CPU 超卖、2小时长期运行 |
| 运行时开销 | Test 6 | CPU/内存/磁盘/网络吞吐与延迟 |
| 内存画像 | Test 7 | VM 固定开销、线性扩展、kubectl 可见性 |

---

## 2. 测试环境

### 架构图

```
┌─────────────────────────────────────────────────────┐
│  L0: AWS 物理机 (Intel Xeon, Nitro Hypervisor)       │
│  ┌───────────────────────────────────────────────┐   │
│  │  L1: EC2 m8i.4xlarge (16 vCPU, 64GB, KVM)     │   │
│  │  Kernel: 6.12.68 Amazon Linux 2023             │   │
│  │  ┌─────────────────────┐ ┌──────────────────┐  │   │
│  │  │  runc container     │ │  Kata microVM    │  │   │
│  │  │  (共享 host 内核)    │ │  QEMU/CLH VMM   │  │   │
│  │  │  └─ App process     │ │  Kernel 6.18.12  │  │   │
│  │  │                     │ │  └─ App process  │  │   │
│  │  └─────────────────────┘ └──────────────────┘  │   │
│  └───────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### 集群配置

| 组件 | 版本/规格 |
|------|----------|
| EKS | 1.34 |
| OpenClaw Operator | v0.22.2 |
| containerd | 2.1.5 |
| Kata Containers | (kata-deploy DaemonSet) |
| QEMU | qemu-system (kata-qemu RuntimeClass) |
| Cloud Hypervisor | CLH (kata-clh RuntimeClass) |
| 节点实例 | m8i.4xlarge (16 vCPU, 64GB), r8i.2xlarge (8 vCPU, 64GB) |
| 工作负载 | OpenClaw gateway 容器 (Test 1-6), pause 容器 (Test 7) |
| 资源配置 | Request: 500m CPU / 1Gi MEM, Limit: 2 CPU / 4Gi MEM (默认) |

### 关键前提

- **Operator v0.22.2 修复**: 之前的 v0.10.7 不传递 `runtimeClassName`，导致所有 "kata" 测试实际跑的是 runc。所有 v2 数据使用修复后的版本重新采集。
- **内核隔离验证**: kata pods 内 `uname -r` = 6.18.12 (VM guest kernel), runc pods = 6.12.68 (host kernel) ✅

---

## 3. Test 1: 单 Pod 冷启动

### 测试目的
量化三种运行时在空闲节点上的启动时间，包括首次冷启动（需要拉取 VM 镜像）和后续热启动。

### 测试方法
- 在空闲 m8i.4xlarge 节点上部署 OpenClaw StatefulSet
- 每种运行时跑 5 轮迭代
- 记录从 `kubectl apply` 到 Pod Ready 的时间
- 验证内核隔离和 gateway 健康

### 测试结果

| Runtime | Iter 1 (冷) | Iter 2 | Iter 3 | Iter 4 | Iter 5 | 平均 (热) | 内核 |
|---------|------------|--------|--------|--------|--------|----------|------|
| runc | 49.22s | 54.84s | 53.13s | 51.32s | 50.26s | 51.75s | 6.12.68 (host) |
| kata-qemu | 119.82s | 67.57s | 75.61s | 74.16s | 64.45s | 70.45s | 6.18.12 (VM) |
| kata-clh | 107.10s | 104.77s | 70.30s | 74.23s | 71.61s | 72.04s | 6.18.12 (VM) |

### 结果分析

1. **首次冷启动**: kata-qemu 119.8s, kata-clh 107.1s — 包含 VM 镜像拉取和缓存建立
2. **热启动 overhead**: Kata 比 runc 慢约 **18-20 秒 (+37%)**
3. **kata-qemu vs kata-clh**: 热启动性能几乎一致（70.4s vs 72.0s）
4. **kata-clh 冷启动更慢**: 前 2 轮都超过 100s，需要更长预热

---

## 4. Test 2: 节点饱和后启动

### 测试目的
模拟节点已有大量 Pod 运行时的启动性能，量化资源争抢对 Kata 启动的影响。

### 测试方法
- 在目标节点 (m8i.4xlarge, 16 vCPU) 预部署 15 个填充 Pod
- 在饱和状态下启动测试 Pod，每种运行时 3 轮

### 测试结果

| Runtime | Iter 1 | Iter 2 | Iter 3 | 平均 |
|---------|--------|--------|--------|------|
| runc | 59.26s | 55.72s | 47.30s | 54.09s |
| kata-qemu | 89.90s | 64.92s | 101.88s | 85.57s |
| kata-clh | 96.21s | 69.04s | 103.96s | 89.74s |

### 结果分析

1. **runc 非常稳定**: 饱和下仅比空闲慢 2s（54s vs 52s）
2. **Kata 波动大**: 范围 65-104s，overhead 增加到 ~32s（空闲时为 ~18s）
3. **CPU 争抢是主因**: Kata 启动需要额外的 VM 初始化 CPU 时间，在饱和节点上被调度器延迟

---

## 5. Test 3: 集群满载后启动

### 测试目的
验证集群级别负载（120 个填充 Pod 跨 10 节点）对启动性能的影响。

### 测试方法
- 在 10 节点集群上部署 120 个填充 Pod（每节点 12 个）
- 在满载集群中启动测试 Pod，每种运行时 3 轮

### 测试结果

| Runtime | Iter 1 | Iter 2 | Iter 3 | 平均 |
|---------|--------|--------|--------|------|
| runc | 49.17s | 52.20s | 52.41s | 51.26s |
| kata-qemu | 68.97s | 69.12s | 67.19s | 68.43s |
| kata-clh | 104.86s | 104.82s | 67.16s | 92.28s |

### 结果分析

1. **runc 完全不受影响**: 51.3s ≈ 空闲时 51.8s
2. **kata-qemu 非常稳定**: 三轮一致在 67-69s
3. **kata-clh 有冷启动惩罚**: 前 2 轮 105s（新节点 VM 镜像缓存），第 3 轮降到 67s
4. **Scheduler 正常**: Pod 均匀分布到各节点

---

## 6. Test 4: 运行时对比（同节点）

### 测试目的
在同一节点上对比三种运行时的启动时间、稳态资源使用和功能正确性。

### 测试方法
- 在 ip-172-31-29-155 上依次部署 runc, kata-qemu, kata-clh
- 等待 idle 后采集 CPU/Memory 和 gateway 健康检查

### 测试结果

| Runtime | 启动时间 | Gateway | CPU (idle) | Memory (idle) | 内核 |
|---------|---------|---------|------------|---------------|------|
| runc | 47.51s | 200 OK ✅ | 1m | 408Mi | 6.12.68 |
| kata-qemu | 69.24s | 200 OK ✅ | 2m | 411Mi | 6.18.12 |
| kata-clh | 66.20s | 200 OK ✅ | 1m | 401Mi | 6.18.12 |

### 结果分析

1. **功能完全一致**: 三种运行时的 gateway 都正常响应
2. **稳态资源几乎相同**: CPU 1-2m, Memory ~400Mi — Kata VM 在 idle 状态下不增加可观测的资源消耗
3. **kata-clh 单次热启动略快**: 66.2s vs 69.2s（但 Test 1 显示 kata-clh 冷启动更慢）

---

## 7. Test 5: 超卖稳定性

### 测试目的
验证 kata-qemu 在 CPU 200% 超卖条件下的长期稳定性，模拟低利用率多租户场景。

### 测试方法
- 节点: r8i.2xlarge (8 vCPU, 64GB RAM)
- 部署 16 个 kata-qemu Pod，每个 Request 400m CPU, Limit 1 CPU
- 总 Request: 6.4 CPU（可调度），总 Limit: 16 CPU（200% 超卖）
- 每 5 分钟采集一次状态，持续 2 小时（24 次检查 × 16 Pod = 384 数据点）

### 测试结果

| 指标 | 值 |
|------|-----|
| 总 Pod 数 | 16 (全部 kata-qemu) |
| 最终存活数 | **16/16 (100%)** |
| OOM 事件 | **0** |
| 最大重启次数 | 2 次 (3 个 Pod) |
| 0 重启 Pod | 6/16 (37.5%) |
| 1 重启 Pod | 7/16 (43.75%) |
| 2 重启 Pod | 3/16 (18.75%) |
| 初始节点 CPU | 8000m (100% 饱和) |
| 稳态节点 CPU | 300-400m (~4%) |
| 稳态节点内存 | ~23.5GB / 64GB (37%) |

### 结果分析

1. **2 小时零 OOM**: 200% CPU 超卖完全可行
2. **重启仅发生在启动阶段**: 前 10 分钟 startup probe 超时导致，稳态后零重启
3. **稳态资源极低**: 每 Pod ~20m CPU，总 ~320m / 8000m (4%)
4. **内存开销**: ~1.5GB/Pod（含 VM overhead），16 Pod = ~23.5GB / 64GB
5. **超卖策略可行**: 对 idle/低利用率工作负载，可以安全超卖到 200%

---

## 8. Test 6: 运行时开销（Runtime Overhead）

### 测试目的
量化嵌套虚拟化 (L1 EC2 → L2 Kata VM) 在 CPU、内存、磁盘、网络四个核心资源维度上的真实运行时开销。

### 测试方法

| 子测试 | 工具 | 测什么 |
|--------|------|--------|
| 6A CPU 计算 | sysbench cpu, 4T, prime=20000 | 纯计算吞吐量 |
| 6B 内存带宽 | sysbench memory, 1M blocks, 10G | 内存总线带宽 |
| 6C 磁盘顺序写 | fio, 1M blocks, direct=1, 30s | 顺序写带宽 |
| 6C 磁盘随机 IO | fio, 4K blocks, 4 jobs, direct=1 | 随机 IOPS |
| 6D 网络 | iperf3, 同节点 pod-to-pod | 吞吐量和延迟 |
| 6E Host CPU | /proc/stat delta | VMM 隐藏 CPU 开销 |
| 6F 综合负载 | stress-ng, CPU+VM+IO 混合 | 混合负载下的表现 |

### 测试结果

| 维度 | runc (baseline) | kata-qemu | kata-clh | kata 开销 |
|------|----------------|-----------|----------|----------|
| **CPU 吞吐** | 5,161 events/s | 5,110 (-1.0%) | 5,109 (-1.0%) | **<1%** ✅ |
| **内存带宽** | 59,431 MiB/s | 60,492 (+1.8%) | 56,792 (-4.4%) | **<5%** ✅ |
| **磁盘顺序写** | 128 MB/s | 2,210 MB/s ⚠️ | 2,094 MB/s ⚠️ | 见分析 |
| **磁盘随机 IOPS** | 1,543 R / 1,555 W | 23,562 R / 23,608 W ⚠️ | 14,656 R / 14,675 W ⚠️ | 见分析 |
| **网络吞吐** | 64.1 Gbps | 31.9 Gbps (-50%) | 16.6 Gbps (-74%) | **🔴 -50~74%** |
| **网络延迟** | 0.06 ms | 0.80 ms | 0.84 ms | **🔴 13x** |
| **Host CPU 开销** | 1.0% | 1.0% | 1.0% | **<1%** ✅ |
| **综合 IO bogo/s** | 10,262 | 442 (-96%) | 367 (-96%) | **🔴 -96%** |

### 结果分析

**1. CPU 计算 (<1% 开销):**  
Intel VT-x 嵌套虚拟化硬件加速生效，L2 VM 的计算指令直接在物理 CPU 执行，不触发额外 VM exit。对 CPU-bound 工作负载几乎无影响。

**2. 内存带宽 (<5% 开销):**  
EPT (Extended Page Tables) 嵌套的 2D 页表遍历开销被 TLB 缓存吸收。kata-clh 略差，可能与 Cloud Hypervisor 的内存虚拟化实现有关。

**3. 磁盘 I/O (⚠️ 数据失真):**  
Kata 数据反而比 runc 快 15-17 倍，原因是 virtiofs 有额外 DAX/page cache 层。`direct=1` 只绕过了 guest 内核 cache，未绕过 VMM 层 cache。**这意味着 Kata 容器内的 fsync 可能不保证数据真正持久化**——这是一个重要的数据安全风险。

**4. 网络 (🔴 最大开销):**  
每个网络包要穿过两次 VMM 的 virtio-net 虚拟网卡，每次触发 VM exit。在嵌套虚拟化下，VM exit 开销叠加 (L2 exit → L1 → L0 → L1 → L2)：
- 吞吐量减半：64 → 32 Gbps (kata-qemu)
- 延迟增 13 倍：0.06 → 0.8ms

**5. Host CPU 隐藏开销 (1%):**  
三种运行时在 `/proc/stat` 层面的 overhead 完全一致（~1%），说明这 1% 是 Linux 内核调度的固有开销，不是 Kata VMM 引入的。QEMU/CLH 在纯计算负载下几乎不消耗额外 CPU。

**6. 稳定性:**
- kata-clh 在高负载下频繁 crash，不得不降低 stress-ng 参数才能完成测试
- kata-qemu 全程稳定

---

## 9. Test 7: 内存占用画像

### 测试目的
精确量化 kata-qemu VM 的真实内存开销，拆解其组成，验证 Kubernetes 监控的盲区。

### 测试方法

| 子测试 | 方法 | 目标 |
|--------|------|------|
| 7A | host `MemAvailable` before/after delta | 单 Pod 真实内存占用 |
| 7B | `/proc/<qemu-pid>/status` + `smaps_rollup` | QEMU 进程内存分解 |
| 7C | cgroup `memory.current` vs `kubectl top` | Kubernetes 监控盲区 |
| 7D | stress-ng 加压 0/256/512/1024 MiB | overhead 是固定还是线性 |
| 7E | 1/2/4/8 pods 部署 | 多 Pod 线性扩展验证 |

节点: ip-172-31-19-254 (m8i.4xlarge, 64 GiB RAM)  
基础镜像: registry.k8s.io/pause:3.10 (最小化应用干扰)

### 7A 测试结果: 单 Pod Idle 内存 Delta

| Runtime | 轮次 1 | 轮次 2 | 轮次 3 | **平均 Delta** |
|---------|-------|-------|-------|--------------|
| runc | -2 MiB | 6 MiB | 9 MiB | **4.3 MiB** |
| kata-qemu | 199 MiB | 206 MiB | 206 MiB | **203.7 MiB** |

> runc 的数值在噪声范围内（pause 容器几乎不用内存），**kata-qemu 的 ~200 MiB 开销完全来自 VM**。

### 7B 测试结果: QEMU 进程 RSS 分解

| 组件 | 大小 | 说明 |
|------|------|------|
| **RssAnon** | ~16 MiB | QEMU 堆内存、设备模拟状态、vCPU 线程栈 |
| **RssFile** | ~84 MiB | QEMU 二进制 + 共享库（从磁盘映射） |
| **RssShmem** | ~168 MiB | Guest RAM（VM 的实际内存，共享内存映射） |
| **VmRSS 合计** | **~269 MiB** | — |
| **PSS** | **~268 MiB** | 几乎无与其他进程的共享 |

> VmRSS ≈ VmHWM 表明 QEMU 的峰值内存等于稳态内存——没有瞬态分配尖峰。

### 7C 测试结果: Cgroup 内存计账

| Runtime | cgroup memory.current |
|---------|----------------------|
| runc | 491,520 bytes (0.47 MiB) |
| kata-qemu | **0 bytes** |

> **关键发现**: kata-qemu 的 pod-level cgroup 报告 **0 bytes**。QEMU 进程的 ~269 MiB RSS 不在 pod cgroup 内计账。**`kubectl top pod` 完全看不到 Kata VM 的内存开销。**

### 7D 测试结果: 不同内存压力下的开销

| 应用内存 (MiB) | runc Delta | kata-qemu Delta | **Kata 净开销** |
|---------------|-----------|-----------------|--------------|
| 0 | 7 | 238 | **231** |
| 256 | 287 | 487 | **200** |
| 512 | 532 | 756 | **224** |
| 1024 | 1,038 | 1,293 | **255** |

**平均净开销: ~228 MiB (标准差 ~23 MiB)**

> 无论应用内存是 0 还是 1024 MiB，Kata VM 的 overhead 恒定在 ~200-255 MiB。这是一个**固定税**，不随工作负载增长。

### 7E 测试结果: 多 Pod 线性扩展

| Pod 数 | runc 总 Delta | kata-qemu 总 Delta | kata 每 Pod 开销 |
|--------|-------------|-------------------|-----------------|
| 1 | 15 MiB | 208 MiB | **208.0 MiB** |
| 2 | 14 MiB | 425 MiB | **212.5 MiB** |
| 4 | 14 MiB | 841 MiB | **210.2 MiB** |
| 8 | 57 MiB | 1,659 MiB | **207.3 MiB** |

> - 每 Pod 开销恒定在 **~207-213 MiB**，完美线性增长
> - **无 VM 间内存去重/共享**：每个 VM 独立的 QEMU 进程 + 独立的 guest 内核
> - 容量估算: 64GB 节点理论上限 ≈ (64,000 - 2,000) / 210 ≈ **295 个 idle kata-qemu Pod**

---

## 10. 综合结论

### 开销总览

| 维度 | 开销 | 评级 | 对 OpenClaw 影响 |
|------|------|------|-----------------|
| 启动时间 | +18-20s (+37%) | ⚠️ 中等 | 可接受，通过预热缓解 |
| CPU 计算 | <1% | ✅ 优秀 | 无影响 |
| 内存带宽 | <5% | ✅ 优秀 | 无影响 |
| 网络吞吐 | -50% | 🔴 严重 | OpenClaw 非网络密集型，0.8ms 延迟可接受 |
| 网络延迟 | 13x (0.06→0.8ms) | 🔴 严重 | 对 AI agent API 调用影响可忽略 |
| 磁盘 I/O | 有 VM cache 层 | ⚠️ 注意 | 需关注数据持久化可靠性 |
| 内存固定开销 | ~200-210 MiB/Pod | ⚠️ 中等 | 需纳入容量规划 |
| kubectl 可见性 | 内存 cgroup 报 0 | 🔴 盲区 | 必须用 host 级监控 |
| 稳态 CPU 开销 | ~1% (与 runc 相同) | ✅ 优秀 | 无影响 |
| 超卖稳定性 | 200% 超卖 2h 零 OOM | ✅ 优秀 | 支持高密度部署 |

### kata-qemu vs kata-clh

| 维度 | kata-qemu | kata-clh | 推荐 |
|------|-----------|----------|------|
| 热启动时间 | ~70s | ~72s | 持平 |
| 冷启动时间 | ~120s | ~107s（但后续轮次不稳定） | kata-qemu |
| CPU 性能 | 与 runc 一致 | 与 runc 一致 | 持平 |
| 网络吞吐 | 32 Gbps | 16.5 Gbps | **kata-qemu** |
| 高负载稳定性 | ✅ 全程稳定 | ❌ 频繁 crash | **kata-qemu** |
| 综合推荐 | **✅ 推荐生产使用** | ❌ 不推荐高负载 | kata-qemu |

---

## 11. 生产部署建议

### 容量规划

```
每节点 Kata Pod 容量 = (节点内存 - 系统预留 - kube 预留) / (应用内存 + 210 MiB)

示例: m8i.4xlarge (64GB)
  系统预留: 2 GB
  可用: 62 GB = 63,488 MiB
  应用 1Gi + Kata 210 MiB = 1,234 MiB/Pod
  最大 Pod 数 ≈ 63,488 / 1,234 ≈ 51 个
  
对比 runc:
  应用 1Gi = 1,024 MiB/Pod
  最大 Pod 数 ≈ 63,488 / 1,024 ≈ 62 个
  损失: ~18% 容量
```

### 监控

1. **不要依赖 `kubectl top pod` 监控 Kata 内存** — cgroup 报 0，完全不可见
2. **必须部署 host 级监控**:
   - Node Exporter + Prometheus: `node_memory_MemAvailable_bytes`
   - 自定义 metric: 通过 DaemonSet 定期执行 `ps aux | grep qemu-system` 采集 RSS
3. **容量告警公式**: `实际使用 = kubectl_top + (kata_pod_count × 210MiB)`

### 启动优化

1. **预热节点**: 首次 Kata Pod 启动需 100-120s（VM 镜像缓存），后续 65-75s
2. **分批启动**: 避免在同一节点同时启动多个 Kata Pod（CPU 争抢导致 startup probe 超时）
3. **调大 startup probe**: 建议 `initialDelaySeconds: 60, failureThreshold: 10`
4. **节点预调度**: 用 DaemonSet 预启动一个 Kata Pod 来预热 VM 镜像缓存

### 运行时选择

| 场景 | 推荐运行时 | 原因 |
|------|----------|------|
| AI Agent (OpenClaw) | **kata-qemu** | CPU-bound，1% 开销无感，0.8ms 延迟可忽略 |
| 网络密集型 (API Gateway) | runc | Kata 网络 -50% 吞吐、13x 延迟不可接受 |
| 数据持久化 | runc | Kata virtiofs cache 可能导致 fsync 不可靠 |
| 多租户安全隔离 | **kata-qemu** | VM 级别隔离，内核独立 |
| 低利用率高密度 | **kata-qemu** + 超卖 | 200% CPU 超卖验证可行 |

### 超卖策略

- **CPU 超卖安全**: 200% 超卖（by limits）验证稳定
- **内存不要超卖**: Kata VM 内存是预分配的，超卖可能导致 OOM
- **建议 Request/Limit 比**: CPU 1:4, Memory 1:1.5
- **Cluster Autoscaler**: 基于 requests 扩容，确保实际内存（含 Kata overhead）不超 85%

### 数据安全注意

⚠️ **Kata 的 virtiofs cache 层会拦截 `direct=1` 的写入**。对于需要强一致性持久化的工作负载（如数据库）：
- 不建议使用 Kata
- 如果必须用，验证 `fsync` 是否真正到达底层存储
- 考虑使用 virtio-blk 替代 virtiofs

---

## 附录: 数据文件索引

| 文件 | 数据量 | 说明 |
|------|-------|------|
| `v2-test1-boot-time.csv` | 15 条 | 冷/热启动时间 |
| `v2-test2-saturated-boot-time.csv` | 9 条 | 节点饱和启动 |
| `v2-test3-multi-node-boot-time.csv` | 9 条 | 集群满载启动 |
| `v2-test4-runtime-comparison.csv` | 3 条 | 运行时对比 |
| `v2-test5-oversell-stability.csv` | 384 条 | 超卖长期监控 |
| `v2-test6-cpu.csv` | 15 条 | CPU benchmark |
| `v2-test6-memory.csv` | 15 条 | 内存带宽 |
| `v2-test6-disk-seqwrite.csv` | 9 条 | 磁盘顺序写 |
| `v2-test6-disk-randio.csv` | 9 条 | 磁盘随机 IO |
| `v2-test6-network.csv` | 9 条 | 网络性能 |
| `v2-test6-host-overhead.csv` | 9 条 | Host CPU 开销 |
| `v2-test6-stress.csv` | 3 条 | 综合负载 |
| `v2-test7a-idle-memory-delta.csv` | 6 条 | 内存 delta |
| `v2-test7b-qemu-rss.csv` | 9 条 | QEMU 进程 RSS |
| `v2-test7c-cgroup-vs-top.csv` | 2 条 | cgroup 对比 |
| `v2-test7d-stress-overhead.csv` | 8 条 | 内存压力测试 |
| `v2-test7e-multi-pod-linearity.csv` | 8 条 | 多 Pod 线性度 |

### 测试脚本

| 脚本 | 用途 |
|------|------|
| `bench-v2.sh` | Test 1-5 主脚本 |
| `bench-v2-test7.sh` | Test 7 主脚本 |
| `v2-lib.sh` | 公共函数库 |
| `test7-memory-footprint.sh` | Test 7 设计稿（未直接使用） |
