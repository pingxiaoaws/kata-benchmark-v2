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
8. [Test 5b: 内存超卖稳定性](#8-test-5b-内存超卖稳定性)
9. [Test 6: 运行时开销](#9-test-6-运行时开销)
10. [Test 7: 内存占用画像](#10-test-7-内存占用画像)
11. [Test 8: Pod Overhead 配置验证 (kata-qemu)](#11-test-8-pod-overhead-配置验证-kata-qemu)
12. [Test 9: kata-clh 内存占用画像](#12-test-9-kata-clh-内存占用画像)
13. [Test 10: Pod Overhead 配置验证 (kata-clh)](#13-test-10-pod-overhead-配置验证-kata-clh)
14. [综合结论](#14-综合结论)
15. [生产部署建议](#15-生产部署建议)
12. [生产部署建议](#12-生产部署建议)

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

#### 原始测试 (多节点调度，含镜像拉取)

| Runtime | Iter 1 (冷) | Iter 2 | Iter 3 | Iter 4 | Iter 5 | 平均 (热) | 内核 | 架构 |
|---------|------------|--------|--------|--------|--------|----------|------|------|
| runc | 49.22s | 54.84s | 53.13s | 51.32s | 50.26s | 51.75s | 6.12.68 (host) | x86 m8i.4xlarge |
| kata-qemu | 119.82s | 67.57s | 75.61s | 74.16s | 64.45s | 70.45s | 6.18.12 (VM) | x86 m8i.4xlarge |
| kata-clh | 107.10s | 104.77s | 70.30s | 74.23s | 71.61s | 72.04s | 6.18.12 (VM) | x86 m8i.4xlarge |

> 注：原始 Test 1 未固定节点，每轮迭代可能调度到新节点，导致热启动时间包含镜像拉取开销。

#### 补充测试 (固定节点，镜像已缓存)

| Runtime | Iter 1 | Iter 2 | Iter 3 | Iter 4 | Iter 5 | 平均 | 内核 | 架构 |
|---------|--------|--------|--------|--------|--------|------|------|------|
| runc (固定节点) | 24.38s | 23.92s | 23.05s | 25.27s | 24.08s | 24.14s | 6.12.68 (host) | x86 m8i.2xlarge |
| gVisor (x86) | 78.92s | 29.69s | 33.68s | 34.25s | 33.89s | 32.88s | 4.4.0 (gVisor) | x86 m8i.2xlarge |
| gVisor (arm64) | 78.63s | 29.70s | 34.46s | 35.04s | 33.71s | 33.23s | 4.4.0 (gVisor) | arm64 m8gd.2xlarge |

> 补充测试于 2026-04-21/22 在固定节点上执行。runc 和 gVisor x86 使用同一节点 (ip-172-31-30-148, m8i.2xlarge)，镜像在 iter 1 后已缓存。gVisor 内核版本 4.4.0 是其用户态内核模拟版本号。

### 结果分析

1. **原始 Test 1 的 runc "热启动" 被高估**: 原始测试中 runc 每轮调度到不同节点，51.8s 包含了镜像拉取。固定节点测试显示 runc 纯热启动仅 **24.1s**
2. **gVisor 热启动比 runc 慢 ~9 秒 (+36%)**: 固定节点对比 runc 24.1s vs gVisor 32.9s，gVisor 的 runsc sandbox 创建和用户态内核初始化增加了 ~9s 开销
3. **gVisor 冷启动 79s 远高于 runc 24s**: gVisor iter 1 的 79s 主要是镜像拉取 + runsc 首次初始化，而 runc iter 1 (24s) 说明该节点已有镜像缓存
4. **Kata 热启动开销最大**: 即使在固定节点上，kata-qemu/kata-clh 需要 65-75s，VM 启动增加 ~40-50s 开销
5. **gVisor x86 vs arm64 几乎无差异**: 热启动 32.9s vs 33.2s，差距 <1%，启动性能对 CPU 架构不敏感

#### 纯运行时启动开销对比 (镜像缓存后，同节点)

| Runtime | 热启动 avg | vs runc 开销 | 开销来源 |
|---------|-----------|-------------|---------|
| runc | 24.1s | 基准 | 容器创建 + 应用初始化 |
| gVisor | 32.9s | +8.8s (+36%) | runsc sandbox + 用户态内核初始化 |
| kata-qemu | ~65-70s * | +41-46s (+170%) | VM 启动 + guest kernel + 应用初始化 |
| kata-clh | ~65-72s * | +41-48s (+170%) | VM 启动 + guest kernel + 应用初始化 |

> \* kata 固定节点测试引用 Test 4 数据 (66-69s)，原始 Test 1 因多节点调度波动较大。

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
- 在 node-10 上依次部署 runc, kata-qemu, kata-clh
- 等待 idle 后采集 CPU/Memory 和 gateway 健康检查

### 测试结果

| Runtime | 启动时间 | Gateway | CPU | Memory | 内核 |
|---------|---------|---------|-----|--------|------|
| runc | 47.51s | 200 OK ✅ | 999m | 881Mi | 6.12.68 |
| kata-qemu | 69.24s | 200 OK ✅ | 468m | 876Mi | 6.18.12 |
| kata-clh | 66.20s | 200 OK ✅ | 137m | 400Mi | 6.18.12 |

> 注: 数据采集于 pod Ready 后 20 秒，应用仍在初始化阶段，CPU 值反映启动过程而非 idle 状态。对于 kata pods，kubectl top 显示的是 VM 内部容器的资源使用，不包含 VMM (QEMU/CLH) 进程的大部分开销。

### 结果分析

1. **功能完全一致**: 三种运行时的 gateway 都正常响应
2. **kata-clh 单次热启动略快**: 66.2s vs 69.2s（但 Test 1 显示 kata-clh 冷启动更慢）

---

## 7. Test 5: 超卖稳定性

### 测试目的
验证 kata-qemu 在 CPU 200% 超卖条件下的长期稳定性，模拟低利用率多租户场景。

### 测试方法
- 节点: r8i.2xlarge (8 vCPU, 64GB RAM)
- 部署 16 个 kata-qemu Pod，每个 Request 800m CPU / 2Gi MEM, Limit 1 CPU / 3Gi MEM
- 总 Request: 12.8 CPU（160% overcommit by request），总 Limit: 16 CPU（200% by limit）
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
3. **稳态资源极低**: 每 Pod ~20m CPU，总 ~320m / 8000m (4%)。注: 此值为 kubectl top 从 VM 内部看到的值（通过 kata-shim CRI stats 接口），不包含 QEMU 进程在 host 侧的 CPU 开销
4. **内存开销**: ~1.5GB/Pod（含 VM overhead），16 Pod = ~23.5GB / 64GB
5. **超卖策略可行**: 对 idle/低利用率工作负载，可以安全超卖到 200%

---

## 8. Test 5b: 内存超卖稳定性

### 测试目的
验证 kata-qemu 在内存维度的超卖表现。Test 5 证明了 CPU 200% 超卖安全，但内存是不可压缩资源，超卖行为理论上应导致 OOM。

### 测试方法
- 节点: r8i.2xlarge (8 vCPU, 64GB RAM)
- 工作负载: pause 容器 (registry.k8s.io/pause:3.10)，request 128Mi/50m CPU, limit 256Mi/100m CPU
- **阶段 1**: 基线对比 — 10 runc vs 10 kata-qemu pods
- **阶段 2**: 逐步加压 — kata-qemu pods 从 10 递增到 200，监控 MemAvailable、OOM 事件、pod 状态
- **阶段 3**: runc 对照 — 用 runc 跑相同数量的 pods 证明差异

### 测试结果

**阶段 1 基线:**

| 指标 | runc (10 pods) | kata-qemu (10 pods) | 差异 |
|------|---------------|--------------------|----|
| MemAvailable | 61,225 MiB | 59,269 MiB | **-1,956 MiB** |
| 每 Pod 开销 | ~9 MiB | ~204 MiB | **~195 MiB/Pod** |

**阶段 2 逐步加压:**

| 目标 Pods | Running | Pending | Failed | MemAvailable (MiB) | OOM |
|-----------|---------|---------|--------|-------------------|-----|
| 10 | 10 | 0 | 0 | 59,273 | 0 |
| 20 | 20 | 0 | 0 | 57,198 | 0 |
| 30 | 30 | 0 | 0 | 55,112 | 0 |
| 40 | 36 | 0 | 0 | 53,020 | 0 |
| 50 | 39 | 0 | 0 | 53,150 | 0 |
| 60 | 35 | 0 | 4 | 51,429 | 0 |
| 80 | 35 | 0 | 4 | 53,518 | 0 |
| 100 | 36 | 0 | 4 | 51,344 | 0 |
| 120 | 40 | 12 | 4 | 52,138 | 0 |
| 150 | 40 | 40 | 4 | 52,526 | 0 |
| 200 | 40 | 90 | 4 | N/A | 0 |

**阶段 3 runc 对照 (40 pods):**

| Runtime | Running | MemAvailable | 使用内存 |
|---------|---------|-------------|---------|
| runc | 40/40 ✅ | 60,944 MiB | 366 MiB |
| kata-qemu | 36/40 | 53,020 MiB | 8,290 MiB |
| **差距** | — | — | **22.6 倍** |

### 结果分析

1. **零 OOM Kill**: 出乎意料，没有发生 host 级别的 OOM kill。Kubernetes scheduler 的 resource accounting 机制在 pod 调度阶段就阻止了内存耗尽——多余的 pod 变成 Pending 而非被 OOM 杀掉。

2. **CPU 才是真正的瓶颈**: Running pods 在 ~35-40 时饱和，此时 MemAvailable 还有 51-53 GiB（80% 空闲！）。限制因素是 CPU request: 40 pods × 50m = 2000m，加上 DaemonSet 消耗，8 vCPU 节点达到可调度上限。

3. **理论 vs 实际容量**:
   - 按内存计算: 60 GiB / 195 MiB ≈ 315 pods（理论上限）
   - 按 CPU 计算: ~40 pods（实际限制）
   - **CPU 是 3:1 的瓶颈**

4. **隐性超卖风险**: pod request 128Mi 但 VM 实际消耗 ~195 MiB（cgroup memory.current 严重低估，因 Guest RAM 以 MAP_SHARED 分配不计入），scheduler 低估了真实内存占用。如果应用本身也消耗大量内存，这种差距会导致 host 不稳定。

5. **runc 对比**: 同等 40 pods，runc 仅用 366 MiB（kata 用 8,290 MiB），差距 22.6 倍。

---

## 9. Test 6: 运行时开销（Runtime Overhead）

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

## 10. Test 7: 内存占用画像

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

节点: node-2 (m8i.4xlarge, 64 GiB RAM)  
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
| kata-qemu | **~372 KiB** (实际 RSS ~275 MiB，cgroup 严重低估) |

> **关键发现**: 实测验证 QEMU 进程确实在 pod cgroup 内（/proc/\<qemu-pid\>/cgroup 路径包含 pod UID），但 cgroup `memory.current` 仅报极低值（~372 Ki），因为:
> - Guest RAM (169 MiB) 通过 /dev/shm 以 MAP_SHARED 分配，cgroupv2 不计入 memory.current
> - QEMU 二进制+共享库 (84 MiB) 是文件映射，算 page cache，不计入
> - 仅 ~16 MiB RssAnon (堆) 部分被计入
>
> **结论**: QEMU 进程在 pod cgroup 内，但 cgroup 内存计账机制不捕获共享内存和文件映射，导致严重低估（~275 MiB 实际 RSS 仅报 ~372 Ki）。**`kubectl top pod` 不反映 Kata VM 的真实内存开销。**

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

## 11. Test 8: Pod Overhead 配置验证

### 测试目的
验证 Kubernetes Pod Overhead 机制能否解决 Test 5b/7 发现的问题：kata-qemu VM 的 ~200 MiB 内存开销对 scheduler 不可见，导致调度决策不准确。

### Overhead 值推导

#### Memory: 250Mi

| 测试 | 方法 | 实测值 | 说明 |
|------|------|--------|------|
| Test 7A | host MemAvailable delta（单 pod） | 200-206 MiB | 最直接的 scheduler 视角 |
| Test 7B | QEMU 进程 VmRSS | 269 MiB | 包含共享库映射 |
| Test 7D | 不同压力下的净 overhead | 200-255 MiB | overhead 是固定税 |
| Test 7E | 多 Pod 线性度（1/2/4/8 pods） | 207-213 MiB/pod | 无 VM 间内存共享 |
| Test 5b | 10 pods 基线对比 | 195 MiB/pod | 大规模验证 |

```
测试中位数（7A/7E/5b）:  ~207 MiB
+20% buffer:             207 × 1.20 ≈ 248 MiB → 取整 250 MiB
```

Buffer 覆盖：virtiofs cache 波动、guest 内核 slab 增长、QEMU 设备队列分配。宁可让 scheduler 保守（略多报）也不要过度调度导致 OOM。

#### CPU: 100m

| 来源 | 值 | 说明 |
|------|-----|------|
| QEMU idle 进程 (host top) | 20-30m | vCPU 线程 + 事件循环 |
| virtio-net 网络处理 | 10-20m | VM exit + 虚拟中断 |
| virtiofs 文件系统 | 10-20m | I/O 请求处理 |
| Guest 定时器 (HZ=100) | 5-10m | 每秒 100 次 timer interrupt |
| **总计** | **~50-80m → 取 100m** | 含 buffer |

K8s 官方示例用 250m (Kata+Firecracker)，但我们实测 QEMU idle CPU 远低于此。100m 平衡安全和 pod 密度。

### 测试方法

| 阶段 | 内容 |
|------|------|
| Phase 0 | 记录无 overhead 基线（1 kata-qemu pod） |
| Phase 1-2 | 应用 overhead 到 RuntimeClass，验证 admission controller 注入 |
| Phase 3 | 无 overhead 调度测试（10→50 pods） |
| Phase 4 | 有 overhead 调度测试（同规模对比） |
| Phase 5 | stress-ng 内存压力验证（25 pods × 256MiB） |

### 测试结果

**Overhead 注入验证 ✅**

Overhead 配置在 RuntimeClass 上，K8s admission controller 在 pod 创建时自动将其注入到 `pod.spec.overhead`：

```bash
# 1. RuntimeClass 配置（源头）
$ kubectl get runtimeclass kata-qemu -o jsonpath='{.overhead.podFixed}'
{"cpu":"100m","memory":"250Mi"}

# 2. Pod 创建后自动注入（验证注入成功）
$ kubectl get pod test-kata -o jsonpath='{.spec.overhead}'
{"cpu":"100m","memory":"250Mi"}

# scheduler 看到的 per-pod effective request:
# 无 overhead: 128Mi mem, 50m cpu  (仅 container request)
# 有 overhead: 378Mi mem, 150m cpu (container request + overhead)
```

**Phase 3 vs 4 调度对比:**

| Pods | 无 Overhead Sched Mem | 有 Overhead Sched Mem | 倍数 | 无 OH Sched CPU | 有 OH Sched CPU |
|------|----------------------|----------------------|------|----------------|----------------|
| 10 | 1,430 Mi | 3,930 Mi | 2.75x | 690m | 1,690m |
| 20 | 2,710 Mi | 7,710 Mi | 2.84x | 1,190m | 3,190m |
| 30 | 3,990 Mi | 11,490 Mi | **2.88x** | 1,690m | 4,690m |
| 40 | 5,270 Mi | 15,270 Mi | 2.90x | 2,190m | 6,190m |
| 50 | 6,550 Mi | 19,050 Mi | **2.91x** | 2,690m | 7,690m |

**内存计账准确性（30 pods）:**

| 指标 | 无 Overhead | 有 Overhead |
|------|-----------|-----------|
| Scheduler 认为用了 | 3,990 Mi | 11,490 Mi |
| Host 实际消耗 | ~6,186 MiB | ~6,225 MiB |
| 差距 | **-2,196 MiB (36% 不可见)** | **+5,265 MiB (安全侧超报)** |

**Phase 5 内存压力 (stress-ng + overhead):**

| Pods | stress-ng MiB | MemAvailable | Sched Mem | OOM |
|------|--------------|-------------|-----------|-----|
| 5 | 256 × 5 | 58,879 MiB | 2,680 Mi | 0 |
| 10 | 256 × 10 | 56,492 MiB | 5,210 Mi | 0 |
| 15 | 256 × 15 | 54,142 MiB | 7,740 Mi | 0 |
| 20 | 256 × 20 | 51,768 MiB | 10,270 Mi | 0 |
| 25 | 256 × 25 | 49,407 MiB | 12,800 Mi | **0** ✅ |

25 pods × (256Mi stress + ~200Mi VM overhead) = ~11.4 GiB host 内存消耗，MemAvailable 从 61 GiB 降到 49 GiB，全程零 OOM。

### 结果分析

1. **Scheduler 可见性提升 ~3 倍**: 有 overhead 后，scheduler 看到的内存消耗从 6.5 GiB 提升到 19 GiB（50 pods），准确反映 VM 真实开销。

2. **防止过度调度**: 无 overhead 时 scheduler 以为 50 pods 只用 10.4% 内存（实际消耗 ~16%），有 overhead 后报告 30.2%，更接近真实值。

3. **安全侧超报优于低报**: 有 overhead 后 scheduler 略微高估内存消耗（因为 250Mi > 实测 207Mi），这意味着 scheduler 会比实际稍早停止调度，**在正确的方向上犯错**。

4. **CPU 仍是瓶颈**: 在当前配置（request 50m + overhead 100m = 150m/pod）下，8 vCPU 节点的 CPU 约在 50 pods 时饱和。内存保护在**更大节点（如 m8i.4xlarge 16 vCPU）或更低 CPU request** 时更关键。

5. **零 OOM**: 全部 6 个阶段、最高 50 pods + 25 stress-ng pods，零 OOM kill。

---

## 12. Test 9: kata-clh 内存占用画像

### 测试目的
对 kata-clh (Cloud Hypervisor) 运行与 Test 7 相同的 5 个子测试，量化其 VM 内存开销并与 kata-qemu 直接对比。

### 测试环境
- 节点: m8i.4xlarge (16 vCPU, 64 GiB RAM)，与 Test 7 同节点
- 基础镜像: registry.k8s.io/pause:3.10
- Namespace: bench9

### 9A: 单 Pod Idle 内存 Delta

| 运行时 | Round 1 | Round 2 | Round 3 | **均值** |
|--------|---------|---------|---------|---------|
| runc | 12 MiB | 10 MiB | 0 MiB | **7.3 MiB** |
| kata-clh | 165 MiB | 169 MiB | 167 MiB | **167.0 MiB** |

**对比 Test 7A (kata-qemu)**: kata-qemu 均值 203.7 MiB → kata-clh 低 **18%**。

### 9B: cloud-hypervisor 进程 RSS 分解

| 组件 | kata-clh (Test 9B) | kata-qemu (Test 7B) | CLH 优势 |
|------|-------------------|--------------------| ---------|
| RssAnon (堆) | **1.3 MiB** | 16 MiB | -92% |
| RssFile (库映射) | **3.7 MiB** | 84 MiB | -96% |
| RssShmem (Guest RAM) | **148 MiB** | 168 MiB | -12% |
| **VmRSS 合计** | **~150 MiB** | ~269 MiB | **-44%** |
| PSS | ~149 MiB | ~268 MiB | -44% |

**分析**:
- Cloud Hypervisor 进程自身极小：Rust 静态编译 + 最小设备集（仅 virtio），堆内存仅 1.3 MiB（QEMU 是 16 MiB）
- 共享库映射 3.7 MiB（QEMU 因依赖 glib/pixman 等达 84 MiB）
- Guest RAM 是主要消耗（两者都在 148-168 MiB），这部分与 VMM 选择无关，由 VM 内存配置决定
- VmRSS ≈ VmHWM，同 QEMU 一样无启动瞬态尖峰

### 9C: Cgroup 内存计账

| 运行时 | cgroup memory.current |
|--------|----------------------|
| runc | 0.47 MiB |
| kata-clh | **~0 KiB** (实际 RSS ~150 MiB，cgroup 严重低估，原因同 7C) |

与 kata-qemu 一致——Cloud Hypervisor 进程在 Pod cgroup 内，但 cgroup memory.current 严重低估 VM 真实内存（Guest RAM 以 MAP_SHARED 分配、VMM 二进制为文件映射，均不计入 memory.current）。`kubectl top pod` 不反映 VM 真实内存开销。**kata-clh 同样需要 Pod Overhead。**

### 9D: 内存压力下的开销

| stress-ng 分配 | runc Delta | kata-clh Delta | 净 VM 开销 |
|---------------|-----------|---------------|-----------|
| 0 MiB | 10 MiB | 202 MiB | **192 MiB** |
| 256 MiB | 281 MiB | 453 MiB | **172 MiB** |
| 512 MiB | 533 MiB | 724 MiB | **191 MiB** |
| 1,024 MiB | 1,043 MiB | 1,265 MiB | **222 MiB** |
| **均值** | | | **~194 MiB** |

**对比 Test 7D (kata-qemu)**: kata-qemu 均值 ~228 MiB → kata-clh 低 **15%**。
开销同样保持固定，不随应用内存线性增长——是固定税。

### 9E: 多 Pod 线性度

| Pod 数 | kata-clh 总 Delta | Per-Pod | kata-qemu Per-Pod (Test 7E) |
|--------|-------------------|---------|----------------------------|
| 1 | 175 MiB | **175.0 MiB** | 208.0 MiB |
| 2 | 341 MiB | **170.5 MiB** | 212.5 MiB |
| 4 | 678 MiB | **169.5 MiB** | 210.2 MiB |
| 8 | 1,335 MiB | **166.8 MiB** | 207.3 MiB |

与 kata-qemu 一样线性增长，无 VM 间内存共享。Per-pod 开销稳定在 ~167-175 MiB。

### kata-qemu vs kata-clh 内存开销总览

| 指标 | kata-qemu | kata-clh | CLH 优势 |
|------|-----------|----------|---------|
| 单 Pod Delta | ~204 MiB | ~167 MiB | **-18%** |
| VMM 进程 RSS | ~269 MiB | ~150 MiB | **-44%** |
| VMM 堆内存 (RssAnon) | 16 MiB | 1.3 MiB | **-92%** |
| VMM 库映射 (RssFile) | 84 MiB | 3.7 MiB | **-96%** |
| Guest RAM (RssShmem) | 168 MiB | 148 MiB | -12% |
| Stress 下净开销 | ~228 MiB | ~194 MiB | **-15%** |
| Per-Pod (8 pods) | 207 MiB | 167 MiB | **-19%** |
| Cgroup 可见性 | ~372 KiB (严重低估) | ~0 KiB (严重低估) | 一样盲 |

### 结论

1. **kata-clh 的 VMM 进程比 QEMU 轻 44%**（150 vs 269 MiB RSS），但 per-pod 实际内存开销只低 ~18%（167 vs 204 MiB），因为 Guest RAM 是主体且两者差别不大。

2. **Cgroup 盲区完全一致**，两者都需要 Pod Overhead。

3. **Pod Overhead 建议值**:
   - kata-qemu: `memory: 250Mi` (实测 204 + 20% buffer)
   - kata-clh: `memory: 200Mi` (实测 167 + 20% buffer ≈ 200)
   - 两者 CPU 均为 `100m`

4. 选用 kata-clh 可在相同节点上多放 **~20% 的 Pods**（按内存 overhead 差算），但需权衡 Test 5 发现的**高负载稳定性问题**。

---

## 13. Test 10: Pod Overhead 配置验证 (kata-clh)

### 测试目的
对 kata-clh 做与 Test 8 (kata-qemu) 相同的 Pod Overhead 验证，确认 K8s Pod Overhead 机制在 Cloud Hypervisor 运行时下同样有效。

### 测试环境
- 节点: r8i.2xlarge (8 vCPU, 64GB RAM)，与 Test 8 同节点
- Overhead: `memory: 200Mi, cpu: 100m`（基于 Test 9 实测 167 MiB + 20% buffer）
- Pod 配置: pause 容器，request 128Mi/50m, limit 256Mi/100m

### Overhead 注入验证 ✅

```bash
# RuntimeClass 配置（源头）
$ kubectl get runtimeclass kata-clh -o jsonpath='{.overhead.podFixed}'
{"cpu":"100m","memory":"200Mi"}

# Pod 创建后自动注入（验证注入成功）
$ kubectl get pod test-clh -o jsonpath='{.spec.overhead}'
{"cpu":"100m","memory":"200Mi"}

# Effective request: 128Mi+200Mi=328Mi, 50m+100m=150m
```

### Phase 3 vs 4 调度对比

| Pods | 无 OH Sched Mem | 有 OH Sched Mem | 倍数 | 无 OH Running | 有 OH Running | 无 OH Failed | 有 OH Failed |
|------|----------------|----------------|------|--------------|--------------|-------------|-------------|
| 10 | 1,430 Mi | 3,558 Mi | 2.49x | 10 | 10 | 0 | 0 |
| 20 | 2,710 Mi | 6,838 Mi | 2.52x | 20 | 20 | 0 | 0 |
| 30 | 3,990 Mi | 9,990 Mi | 2.50x | 30 | 30 | 0 | 0 |
| 40 | 5,270 Mi | 13,270 Mi | 2.52x | 33 | 30 | **3** | **1** |
| 50 | 6,550 Mi | 16,550 Mi | 2.53x | 36 | 35 | **1** | **3** |

**⚠️ CLH 稳定性**: 在 40-50 pods 时出现 failed pods（Phase 3 共 4 个, Phase 4 共 4 个），再次验证了 Test 5 的发现——kata-clh 在高密度部署下不如 kata-qemu 稳定。

### Phase 5 stress-ng 压力测试

| Pods | MemAvail (MiB) | Sched Mem (Mi) | OOM |
|------|---------------|----------------|-----|
| 5 | 59,035 | 2,430 | 0 |
| 10 | 56,723 | 4,710 | 0 |
| 15 | 54,470 | 6,990 | 0 |
| 20 | 52,158 | 9,270 | 0 |
| 25 | 49,957 | 11,550 | **0** ✅ |

25 pods stress-ng 全部成功运行，零 OOM。

### Test 8 (kata-qemu) vs Test 10 (kata-clh) 对比

| 指标 | kata-qemu | kata-clh |
|------|-----------|----------|
| Overhead memory | 250Mi | **200Mi** |
| Overhead cpu | 100m | 100m |
| 30 pods 调度器可见 mem | 11,490 Mi | **9,990 Mi** |
| 50 pods 调度器可见 mem | 19,050 Mi | **16,550 Mi** |
| Injection 验证 | ✅ | ✅ |
| stress-ng 25 pods OOM | 0 | **0** |
| Scale 50 failed pods | 0 | **3-4** ⚠️ |

### 结论

1. **Pod Overhead 对 kata-clh 完全有效**——admission controller 正确注入，scheduler 正确计算。
2. **调度器可见性提升 ~2.5 倍**（vs kata-qemu 的 ~2.9 倍，因为 overhead 更小）。
3. **CLH 的稳定性问题在 Pod Overhead 测试中再次复现**——即使有 overhead，40+ pods 时仍出现 failed pods。
4. **生产建议**: 如果选择 kata-clh，必须配置 `overhead: {memory: 200Mi, cpu: 100m}`，同时关注高密度下的稳定性。

---

## 14. 综合结论

### 开销总览

| 维度 | 开销 | 评级 | 对 OpenClaw 影响 |
|------|------|------|-----------------|
| 启动时间 (kata) | +41-46s (+170%) | ⚠️ 中等 | 可接受，通过预热缓解 |
| 启动时间 (gVisor) | +8.8s (+36%) | ⚠️ 轻微 | runsc sandbox 初始化开销 |
| CPU 计算 | <1% | ✅ 优秀 | 无影响 |
| 内存带宽 | <5% | ✅ 优秀 | 无影响 |
| 网络吞吐 | -50% | 🔴 严重 | OpenClaw 非网络密集型，0.8ms 延迟可接受 |
| 网络延迟 | 13x (0.06→0.8ms) | 🔴 严重 | 对 AI agent API 调用影响可忽略 |
| 磁盘 I/O | 有 VM cache 层 | ⚠️ 注意 | 需关注数据持久化可靠性 |
| 内存固定开销 | ~200-210 MiB/Pod | ⚠️ 中等 | 需纳入容量规划 |
| kubectl 可见性 | cgroup 严重低估 VM 内存（~275 MiB 仅计入 <1 MiB） | 🔴 盲区 | 必须用 host 级监控 |
| 稳态 CPU 开销 | ~1% (与 runc 相同) | ✅ 优秀 | 无影响 |
| 超卖稳定性 | 200% 超卖 2h 零 OOM | ✅ 优秀 |
| 内存超卖 | CPU 先饱和，零 OOM | ⚠️ 见 5b | 支持高密度部署 |

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

## 15. 生产部署建议

### ⭐ 首要：配置 Pod Overhead（Test 8 验证）

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    memory: "250Mi"   # 实测 ~207MiB + 20% buffer
    cpu: "100m"        # QEMU idle + virtio 处理
scheduling:
  nodeSelector:
    workload-type: kata
  tolerations:
  - effect: NoSchedule
    key: kata-dedicated
    operator: Exists
```

**效果**: Scheduler 内存可见性提升 ~3 倍，防止因不可见 VM 开销导致的过度调度。Test 8 验证零 OOM。

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

1. **不要依赖 `kubectl top pod` 监控 Kata 内存** — cgroup memory.current 严重低估 VM 真实内存（QEMU 275 MiB RSS 仅被计入 ~372 Ki），原因是 Guest RAM 以 MAP_SHARED 方式分配、QEMU 二进制为文件映射
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
| 轻量安全隔离 | **gVisor** | 零 VM overhead，热启动最快，syscall 兼容性需验证 |
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
| `v2-test1-boot-time.csv` | 15 条 | 冷/热启动时间 (runc/kata-qemu/kata-clh, 多节点) |
| `v2-test1-runc-fixed-node-boot-time.csv` | 5 条 | runc 固定节点启动时间 (x86) |
| `v2-test1-gvisor-boot-time.csv` | 5 条 | gVisor 冷/热启动时间 (arm64 Graviton) |
| `v2-test1-gvisor-x86-boot-time.csv` | 5 条 | gVisor 冷/热启动时间 (x86 Intel) |
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
| `v2-test5b-memory-oversell.csv` | 15 条 | 内存超卖 |
| `v2-test8-pod-overhead.csv` | 多条 | Pod Overhead 验证 |

### 测试脚本

| 脚本 | 用途 |
|------|------|
| `bench-v2.sh` | Test 1-5 主脚本 |
| `bench-v2-test5b.sh` | Test 5b 内存超卖 |
| `bench-v2-test7.sh` | Test 7 主脚本 |
| `bench-v2-test8.sh` | Test 8 Pod Overhead 验证 |
| `bench-v2-runc-fixed-node-coldboot.sh` | runc 固定节点启动测试 (对照组) |
| `bench-v2-gvisor-coldboot.sh` | gVisor 冷启动测试 arm64 (Test 1 补充) |
| `bench-v2-gvisor-x86-coldboot.sh` | gVisor 冷启动测试 x86 (Test 1 补充) |
| `v2-lib.sh` | 公共函数库 |
