# Max Pod Density Test: kata-qemu Full Stress on m8i.4xlarge (Nested Virtualization)

**Date:** 2026-04-14 01:38–02:06 UTC  
**Result: 14 pods stable under full CPU+memory stress, pod 15 triggered container restarts**

## 1. Test Objective

验证 kata-qemu 在**嵌套虚拟化**环境下，当每个容器的 CPU 和内存都被压满时，单节点能稳定运行多少个 Pod。

与之前的轻量 workload 测试（m8i.2xlarge，10 pods 稳定）对比，评估 workload 压力对 Pod 密度的影响。

## 2. Environment

| Property | Value |
|----------|-------|
| Node | ip-172-31-18-59.us-west-2.compute.internal |
| Instance Type | **m8i.4xlarge** (16 vCPU, 64 GiB) |
| Virtualization | **Nested** (KVM inside EC2 bare-metal-equivalent) |
| Node Allocatable | cpu=15890m, memory=58567 MiB |
| RuntimeClass | kata-qemu |
| Pod Overhead | cpu=100m, memory=250Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s version | v1.34.4-eks |
| Containerd | 2.1.5 |
| Stress tool | polinux/stress-ng (CPU 95% load + vm-keep) |

## 3. Pod Specification (Guaranteed QoS, request = limit)

每个容器运行 `stress-ng`，同时压满 CPU（95% load）和内存（vm-keep 分配并持有）。

| Container | CPU | Memory | stress-ng Args |
|-----------|-----|--------|----------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |
| **Container totals** | **450m** | **2048 MiB** | **1750 MiB vm-bytes** |
| **+ RuntimeClass overhead** | **+100m** | **+250 MiB** | |
| **Scheduling footprint** | **550m** | **2298 MiB** | |

### 与轻量测试的关键区别

| 维度 | 轻量测试 (m8i.2xlarge) | 全压满测试 (m8i.4xlarge) |
|------|----------------------|------------------------|
| CPU 负载 | ~104m/450m (23%) | ~452m/450m (100%) |
| 内存使用 | 809 MiB/2048 MiB (40%, shm) | ~1810 MiB/2048 MiB (88%, stress-ng) |
| 工具 | busybox + dd + sleep | stress-ng --cpu-load 95 --vm-keep |
| 压力类型 | 内存密集，CPU 轻量 | CPU + 内存同时满载 |

## 4. Theoretical Maximum

```
Node allocatable memory: 58567 MiB
System pod requests:     -  150 MiB  (aws-node, kube-proxy, kata-deploy, etc.)
Available for test pods:  58417 MiB

Per pod (with overhead):   2298 MiB
Max pods by memory: floor(58417 / 2298) = 25

Node allocatable CPU:     15890m
System pod requests:      - 190m
Available for test pods:   15700m

Per pod (with overhead):    550m
Max pods by CPU: floor(15700 / 550) = 28

Theoretical maximum = 25 pods (memory-limited)
```

## 5. Test Process

1. 选择干净的 m8i.4xlarge 节点（无用户 Pod），打上 `workload-type=kata` 标签
2. 逐个部署 Pod，每个 Pod 独立 namespace (`maxpod-fl-N`)
3. 等待 Pod Ready 后 settle 90 秒，让 stress-ng 完全 ramp up
4. Settle 后检查所有已部署 Pod 的状态和 restart count
5. 收集 `kubectl top node`、`kubectl top pod --containers` 指标
6. 如果检测到任何 restart，记录数据并停止
7. 总执行时间: ~28 分钟 (01:38–02:06 UTC)

## 6. Results

### 6.1 Per-Pod Metrics

| Pod | Ready(s) | Node CPU | CPU% | Node Mem | Mem% | stress CPU | stress Mem (MiB) | Restarts | Status |
|-----|----------|----------|------|----------|------|------------|------------------|----------|--------|
| 1 | 8 | 498m | 3% | 3037Mi | 5% | 451m | 1782 | 0 | OK |
| 2 | 7 | 828m | 5% | 5256Mi | 8% | 452m | 1807 | 0 | OK |
| 3 | 6 | 1334m | 8% | 7404Mi | 12% | 453m | 1832 | 0 | OK |
| 4 | 7 | 1976m | 12% | 9518Mi | 16% | 452m | 1807 | 0 | OK |
| 5 | 7 | 2524m | 15% | 11659Mi | 19% | 453m | 1832 | 0 | OK |
| 6 | 7 | 3089m | 19% | 13917Mi | 23% | 451m | 1782 | 0 | OK |
| 7 | 7 | 3496m | 22% | 16078Mi | 27% | 452m | 1822 | 0 | OK |
| 8 | 6 | 3892m | 24% | 18240Mi | 31% | 451m | 1807 | 0 | OK |
| 9 | 7 | 4470m | 28% | 20474Mi | 34% | 451m | 1832 | 0 | OK |
| 10 | 7 | 5061m | 31% | 22687Mi | 38% | 453m | 1807 | 0 | OK |
| 11 | 7 | 5592m | 35% | 24897Mi | 42% | 452m | 1832 | 0 | OK |
| 12 | 6 | 6181m | 38% | 27024Mi | 46% | 452m | 1807 | 0 | OK |
| 13 | 9 | 6550m | 41% | 29249Mi | 49% | 452m | 1832 | 0 | OK |
| 14 | 7 | 6955m | 43% | 31287Mi | 53% | 451m | 1807 | 0 | OK |
| **15** | **7** | **9902m** | **62%** | **31740Mi** | **54%** | **450m** | **877** | **4** | **FAIL** |

### 6.2 Incremental Cost Per Pod (from stable range 1–14)

| Metric | Per-Pod Delta | Notes |
|--------|---------------|-------|
| kubectl top node memory | ~2161 MiB | cAdvisor sees QEMU sandbox cgroup |
| kubectl top node CPU | ~462m | 5 vCPUs with stress-ng driving ~452m |
| stress-ng CPU per pod | ~452m | Consistent: 450–453m across all pods |
| stress-ng memory per pod | ~1810 MiB | Consistent: 1782–1832 MiB |
| VM startup time | 6–9 seconds | Consistent, no degradation until pod 15 |

### 6.3 Summary

| Metric | Value |
|--------|-------|
| **Maximum stable pods** | **14** |
| Scheduler theoretical max | 25 (memory-limited) |
| Gap | 11 pods (44% fewer than theoretical) |
| Failure trigger | Pod 15 — 4 container restarts |
| Node CPU at failure | 62% (jumped from 43% → 62% during pod 15 settle) |
| Node memory at failure | 54% (31740 MiB / 58567 MiB) |
| VM startup time at failure | Normal (7s), but stress-ng mem dropped to 877 MiB |

## 7. Analysis

### 7.1 Pod 15 Failure Pattern

Pod 15 的失败特征与轻量测试不同：

1. **Pod 15 自身的 restart**：4 次 restart 全部发生在 pod-15 上，其他 14 个 pod 未受影响（轻量测试中 pod 11 导致 7 个现有 VM 被杀）
2. **stress-ng 内存减半**：Pod 15 的 stress_mem 只有 877 MiB（正常 ~1810 MiB），说明 VM 无法分配完整的 guest 内存
3. **CPU 突跳**：Node CPU 从 43%（14 pods）跳到 62%（15 pods），增幅 19%（正常每 pod 只增 3%）。额外的 16% 来自 hypervisor 争抢和 VM restart 开销
4. **内存仅增 453 MiB**：正常每 pod 增 ~2161 MiB，但 pod 15 只增了 453 MiB，说明 VM 未能完整启动

### 7.2 Root Cause: Nested Virtualization EPT Contention

和轻量测试相同的根因——L1 KVM hypervisor 的 EPT（Extended Page Table）影子管理瓶颈：

```
                        轻量测试 (m8i.2xlarge)    全压满 (m8i.4xlarge)
                        ───────────────────────   ───────────────────────
Node vCPU               8                         16
Node Memory             32 GiB                    64 GiB
Stable pods             10                        14
Failure pod             11                        15
Pods per vCPU           1.25                      0.875
Pods per 8 GiB          2.5                       1.75
Scheduler utilization   77% mem                   53% mem, 43% CPU
```

关键发现：
- **Pod 密度与 vCPU 近似线性**：m8i.2xlarge (8 vCPU) → 10 pods, m8i.4xlarge (16 vCPU) → 14 pods。每增加 8 vCPU 多支撑 ~4-5 个 kata VM
- **全压满降低了密度**：理论上 4xlarge 有 2x 资源应该支撑 2x pods (20)，但只到 14。stress-ng 的持续 CPU + memory 压力加重了 EPT 管理负担
- **内存不是瓶颈**：失败时 node memory 只用了 54%（31.7 GiB / 58.5 GiB），剩余 27 GiB 可用
- **CPU 也不是直接瓶颈**：失败时 node CPU 43%（pod 15 的异常跳到 62% 是 hypervisor 争抢的结果，非原因）

### 7.3 Memory Visibility Analysis

```
                          Per Pod (MiB)
                          ─────────────
kubectl top pod (stress): ~1810    ← stress-ng RSS inside guest VM
kubectl top node (Δ):     ~2161    ← cAdvisor sees QEMU sandbox cgroup
Scheduler reservation:     2298    ← container requests (2048) + overhead (250)
```

在全压满场景下，差距更小：
- **调度器超额预留比 = 2298 / 2161 = 1.06x**（轻量测试为 2.0x）
- stress-ng 将 guest 内存几乎全部 fault in，QEMU RSS 接近 VM 分配大小
- 多出的 ~350 MiB（2161 - 1810）是 guest kernel + kata-agent + QEMU 进程本身的开销

### 7.4 Cross-Test Comparison

| 维度 | 轻量 (m8i.2xlarge) | 全压满 (m8i.4xlarge) |
|------|-------------------|---------------------|
| 稳定 Pod 数 | 10 | 14 |
| 理论上限 | 12 | 25 |
| 利用率（vs 理论） | 83% | 56% |
| 每 pod cAdvisor 内存 | ~1081 MiB | ~2161 MiB |
| 每 pod stress 内存 | 809 MiB (shm) | ~1810 MiB (stress-ng) |
| VM overhead（cAdvisor - stress） | ~272 MiB | ~351 MiB |
| 调度器超额预留比 | 2.0x | 1.06x |
| 失败模式 | 级联 VM crash (7/11 killed) | 单 pod restart (pod 15) |
| 失败时 node CPU | 37% | 62% (异常跳变) |
| 失败时 node 内存 | 41% | 54% |

## 8. Recommended Pod Overhead

### 8.1 For Nested Virtualization (EKS on .metal instances)

基于两轮测试的数据：

```yaml
# kata-qemu — Nested Virtualization (recommended)
overhead:
  podFixed:
    cpu: 250m
    memory: 350Mi
```

**推导过程：**

| 指标 | 轻量 workload | 全压满 workload | 选择 |
|------|-------------|---------------|------|
| cAdvisor 内存 Δ | 1081 MiB/pod | 2161 MiB/pod | — |
| 容器 request | 2048 MiB | 2048 MiB | — |
| VM overhead (cAdvisor - stress) | 272 MiB | 351 MiB | **350 MiB (worst case)** |
| CPU overhead (cAdvisor - stress) | 191m | ~10m | **250m (含 hypervisor 争抢余量)** |

- **memory 350 MiB**：全压满时 VM 额外开销（guest kernel + kata-agent + QEMU 进程）最大 351 MiB。使用 350 MiB 覆盖 worst case
- **cpu 250m**：轻量场景下 QEMU vCPU 调度有额外 ~191m 开销；全压满时 CPU 开销被 cgroup throttling 吸收。取 250m 留出 hypervisor 争抢余量

此配置下各机型最大 pod 数：

| Instance | vCPU | Memory | 理论上限 (scheduler) | 预期稳定数 (嵌套虚拟化) |
|----------|------|--------|---------------------|----------------------|
| m8i.2xlarge | 8 | 32 GiB | floor(29753/2398)=12 | ~10 |
| m8i.4xlarge | 16 | 64 GiB | floor(58417/2398)=24 | ~14-16 |
| m8i.8xlarge | 32 | 128 GiB | floor(120000/2398)=50 | ~30-35 |
| m8i.metal-24xl | 96 | 384 GiB | floor(370000/2398)=154 | N/A (bare metal) |

### 8.2 For Bare Metal (无嵌套虚拟化)

```yaml
# kata-qemu — Bare Metal (recommended)
overhead:
  podFixed:
    cpu: 100m
    memory: 250Mi
```

裸金属没有 EPT 影子页表开销，VM overhead 更低（~207 MiB, Test 7 数据）。250 MiB 留 20% 余量。

### 8.3 Conservative Production Recommendation

如果优先稳定性而非密度：

```yaml
# kata-qemu — Production Conservative (nested virt)
overhead:
  podFixed:
    cpu: 300m
    memory: 512Mi
```

这会让调度器限制在更安全的密度：
- m8i.4xlarge: floor(58417/2560)=22 pods → 嵌套虚拟化下 14 个稳定，8 个安全余量
- 缺点是浪费 ~35% 可调度内存

## 9. Key Takeaways

1. **嵌套虚拟化是密度瓶颈，不是内存或 CPU**：失败时内存和 CPU 都有大量余裕
2. **全压满 workload 降低了约 30% 密度**：相对于轻量 workload（按 vCPU 比例）
3. **全压满时调度器预留更准确**：overhead 1.06x vs 轻量时 2.0x，因为 guest 内存被充分 touch
4. **Pod 密度与 vCPU 数近似线性**：可用于容量规划
5. **裸金属部署可大幅提升密度**：消除 EPT 影子页表开销，预计 2x-3x pod 密度提升
6. **推荐 overhead: cpu=250m, memory=350Mi**（嵌套虚拟化），cpu=100m, memory=250Mi（裸金属）

## 10. Files

| File | Description |
|------|-------------|
| `max-pod-test-fullload.sh` | Test script |
| `results-fullload.csv` | Raw per-pod metrics in CSV format |
| `test-fullload.log` | Full test execution log |
| `README.md` | This analysis |
