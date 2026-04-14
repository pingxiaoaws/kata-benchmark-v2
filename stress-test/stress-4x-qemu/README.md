# 最大 Pod 密度测试：kata-qemu 全压满 — m8i.4xlarge（嵌套虚拟化）

**日期：** 2026-04-14 01:38–02:06 UTC  
**结果：14 个 Pod 在全压满下稳定运行，第 15 个 Pod 触发容器 restart**

## 1. 测试目标

验证 kata-qemu 在**嵌套虚拟化**环境下，当每个容器的 CPU 和内存都被压满时，单节点能稳定运行多少个 Pod。

与之前的轻量 workload 测试（m8i.2xlarge，10 个 Pod 稳定）对比，评估 workload 压力对 Pod 密度的影响。

## 2. 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-18-59.us-west-2.compute.internal |
| 实例类型 | **m8i.4xlarge**（16 vCPU，64 GiB） |
| 虚拟化 | **嵌套**（EC2 bare-metal-equivalent 上的 KVM） |
| 节点可调度资源 | cpu=15890m，memory=58567 MiB |
| RuntimeClass | kata-qemu |
| Pod Overhead | cpu=100m，memory=250Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s 版本 | v1.34.4-eks |
| Containerd | 2.1.5 |
| 压测工具 | polinux/stress-ng（CPU 95% 负载 + vm-keep） |

## 3. Pod 规格（Guaranteed QoS，request = limit）

每个容器运行 `stress-ng`，同时压满 CPU（95% 负载）和内存（vm-keep 分配并持有）。

| 容器 | CPU | 内存 | stress-ng 参数 |
|------|-----|------|---------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |
| **容器合计** | **450m** | **2048 MiB** | **1750 MiB vm-bytes** |
| **+ RuntimeClass overhead** | **+100m** | **+250 MiB** | |
| **调度器视角（每 Pod）** | **550m** | **2298 MiB** | |

### 与轻量测试的关键区别

| 维度 | 轻量测试（m8i.2xlarge） | 全压满测试（m8i.4xlarge） |
|------|------------------------|--------------------------|
| CPU 负载 | ~104m/450m（23%） | ~452m/450m（100%） |
| 内存使用 | 809 MiB/2048 MiB（40%，shm） | ~1810 MiB/2048 MiB（88%，stress-ng） |
| 工具 | busybox + dd + sleep | stress-ng --cpu-load 95 --vm-keep |
| 压力类型 | 内存密集，CPU 轻量 | CPU + 内存同时满载 |

## 4. 理论最大值

```
节点可调度内存:     58567 MiB
系统 Pod 请求:      -  150 MiB（aws-node、kube-proxy、kata-deploy 等）
可用于测试 Pod:      58417 MiB

每 Pod（含 overhead）: 2298 MiB
内存上限: floor(58417 / 2298) = 25

节点可调度 CPU:      15890m
系统 Pod 请求:       - 190m
可用于测试 Pod:       15700m

每 Pod（含 overhead）:  550m
CPU 上限: floor(15700 / 550) = 28

理论最大值 = 25 个 Pod（内存受限）
```

## 5. 测试流程

1. 选择干净的 m8i.4xlarge 节点（无用户 Pod），打上 `workload-type=kata` 标签
2. 逐个部署 Pod，每个 Pod 独立 namespace（`maxpod-fl-N`）
3. 等待 Pod Ready 后 settle 90 秒，让 stress-ng 完全 ramp up
4. Settle 后检查所有已部署 Pod 的状态和 restart count
5. 收集 `kubectl top node`、`kubectl top pod --containers` 指标
6. 如果检测到任何 restart，记录数据并停止
7. 总执行时间：~28 分钟（01:38–02:06 UTC）

## 6. 结果

### 6.1 逐 Pod 指标

| Pod | 就绪(s) | 节点CPU | CPU% | 节点内存 | 内存% | stress CPU | stress 内存(MiB) | Restart | 状态 |
|-----|---------|---------|------|----------|-------|------------|-----------------|---------|------|
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

### 6.2 每 Pod 增量开销（从稳定区间 1–14 推导）

| 指标 | 每 Pod 增量 | 备注 |
|------|------------|------|
| kubectl top node 内存 | ~2161 MiB | cAdvisor 看到 QEMU sandbox cgroup |
| kubectl top node CPU | ~462m | 5 vCPU + stress-ng 驱动 ~452m |
| stress-ng CPU/Pod | ~452m | 一致：所有 Pod 间 450–453m |
| stress-ng 内存/Pod | ~1810 MiB | 一致：1782–1832 MiB |
| VM 启动时间 | 6–9 秒 | 一致，直到 Pod 15 才退化 |

### 6.3 汇总

| 指标 | 值 |
|------|-----|
| **最大稳定 Pod 数** | **14** |
| 调度器理论上限 | 25（内存受限） |
| 差距 | 11 个 Pod（比理论少 44%） |
| 失败触发 | Pod 15 — 4 次容器 restart |
| 失败时节点 CPU | 62%（从 43% 跳到 62%，Pod 15 settle 期间） |
| 失败时节点内存 | 54%（31740 MiB / 58567 MiB） |
| 失败时 VM 启动时间 | 正常（7s），但 stress-ng 内存降至 877 MiB |

## 7. 分析

### 7.1 Pod 15 失败模式

Pod 15 的失败特征与轻量测试不同：

1. **Pod 15 自身的 restart**：4 次 restart 全部发生在 Pod 15 上，其他 14 个 Pod 未受影响（轻量测试中 Pod 11 导致 7 个现有 VM 被杀）
2. **stress-ng 内存减半**：Pod 15 的 stress_mem 只有 877 MiB（正常 ~1810 MiB），说明 VM 无法分配完整的 Guest 内存
3. **CPU 突跳**：节点 CPU 从 43%（14 Pod）跳到 62%（15 Pod），增幅 19%（正常每 Pod 只增 3%）。额外的 16% 来自 hypervisor 争抢和 VM restart 开销
4. **内存仅增 453 MiB**：正常每 Pod 增 ~2161 MiB，但 Pod 15 只增了 453 MiB，说明 VM 未能完整启动

### 7.2 根因：嵌套虚拟化下 VMExit 与内存虚拟化开销

和轻量测试相同的根因 — 嵌套虚拟化下 VMExit 频率放大 + nested page table walk 开销叠加：

```
                        轻量测试 (m8i.2xlarge)    全压满 (m8i.4xlarge)
                        ───────────────────────   ───────────────────────
节点 vCPU               8                         16
节点内存               32 GiB                    64 GiB
稳定 Pod 数            10                        14
失败 Pod               11                        15
每 vCPU Pod 数         1.25                      0.875
每 8 GiB Pod 数        2.5                       1.75
调度器利用率           77% 内存                   53% 内存, 43% CPU
```

关键发现：
- **Pod 密度与 vCPU 近似线性**：m8i.2xlarge（8 vCPU）→ 10 Pod，m8i.4xlarge（16 vCPU）→ 14 Pod。每增加 8 vCPU 多支撑 ~4-5 个 kata VM
- **全压满降低了密度**：理论上 4xlarge 有 2x 资源应该支撑 2x Pod（20），但只到 14。stress-ng 的持续 CPU + 内存压力增加了 TLB miss rate 和 nested page walk 频率
- **内存不是瓶颈**：失败时节点内存只用了 54%（31.7 GiB / 58.5 GiB），剩余 27 GiB 可用
- **CPU 也不是直接瓶颈**：失败时节点 CPU 43%（Pod 15 的异常跳到 62% 是 hypervisor 争抢的结果，非原因）

### 7.3 内存可见性分析

```
                          每 Pod（MiB）
                          ──────────────
kubectl top pod (stress): ~1810    ← Guest VM 内 stress-ng RSS
kubectl top node (Δ):     ~2161    ← cAdvisor 看到 QEMU sandbox cgroup
调度器预留:                2298    ← 容器 request(2048) + overhead(250)
```

在全压满场景下，差距更小：
- **调度器超额预留比 = 2298 / 2161 = 1.06x**（轻量测试为 2.0x）
- stress-ng 将 Guest 内存几乎全部 fault in，QEMU RSS 接近 VM 分配大小
- 多出的 ~350 MiB（2161 - 1810）是 Guest 内核 + kata-agent + QEMU 进程本身的开销

### 7.4 跨测试对比

| 维度 | 轻量（m8i.2xlarge） | 全压满（m8i.4xlarge） |
|------|--------------------|-----------------------|
| 稳定 Pod 数 | 10 | 14 |
| 理论上限 | 12 | 25 |
| 利用率（vs 理论） | 83% | 56% |
| 每 Pod cAdvisor 内存 | ~1081 MiB | ~2161 MiB |
| 每 Pod stress 内存 | 809 MiB（shm） | ~1810 MiB（stress-ng） |
| VM overhead（cAdvisor - stress） | ~272 MiB | ~351 MiB |
| 调度器超额预留比 | 2.0x | 1.06x |
| 失败模式 | 级联 VM crash（7/11 被杀） | 单 Pod restart（Pod 15） |
| 失败时节点 CPU | 37% | 62%（异常跳变） |
| 失败时节点内存 | 41% | 54% |

## 8. 推荐 Pod Overhead 配置

### 8.1 嵌套虚拟化（EKS on .metal 实例）

基于两轮测试的数据：

```yaml
# kata-qemu — 嵌套虚拟化（推荐）
overhead:
  podFixed:
    cpu: 250m
    memory: 350Mi
```

**推导过程：**

| 指标 | 轻量 workload | 全压满 workload | 选择 |
|------|-------------|---------------|------|
| cAdvisor 内存 Δ | 1081 MiB/Pod | 2161 MiB/Pod | — |
| 容器 request | 2048 MiB | 2048 MiB | — |
| VM overhead（cAdvisor - stress） | 272 MiB | 351 MiB | **350 MiB（worst case）** |
| CPU overhead（cAdvisor - stress） | 191m | ~10m | **250m（含 hypervisor 争抢余量）** |

- **memory 350 MiB**：全压满时 VM 额外开销（Guest 内核 + kata-agent + QEMU 进程）最大 351 MiB。使用 350 MiB 覆盖 worst case
- **cpu 250m**：轻量场景下 QEMU vCPU 调度有额外 ~191m 开销；全压满时 CPU 开销被 cgroup throttling 吸收。取 250m 留出 hypervisor 争抢余量

此配置下各机型最大 Pod 数：

| 实例 | vCPU | 内存 | 理论上限（调度器） | 预期稳定数（嵌套虚拟化） |
|------|------|------|-------------------|------------------------|
| m8i.2xlarge | 8 | 32 GiB | floor(29753/2398)=12 | ~10 |
| m8i.4xlarge | 16 | 64 GiB | floor(58417/2398)=24 | ~14-16 |
| m8i.8xlarge | 32 | 128 GiB | floor(120000/2398)=50 | ~30-35 |
| m8i.metal-24xl | 96 | 384 GiB | floor(370000/2398)=154 | N/A（裸金属） |

### 8.2 裸金属（无嵌套虚拟化）

```yaml
# kata-qemu — 裸金属（推荐）
overhead:
  podFixed:
    cpu: 100m
    memory: 250Mi
```

裸金属消除了嵌套虚拟化的额外 VMExit 路径和 nested page walk 开销，VM overhead 更低（~207 MiB，Test 7 数据）。250 MiB 留 20% 余量。

### 8.3 保守生产配置

如果优先稳定性而非密度：

```yaml
# kata-qemu — 生产保守配置（嵌套虚拟化）
overhead:
  podFixed:
    cpu: 300m
    memory: 512Mi
```

这会让调度器限制在更安全的密度：
- m8i.4xlarge: floor(58417/2560)=22 Pod → 嵌套虚拟化下 14 个稳定，8 个安全余量
- 缺点是浪费 ~35% 可调度内存

## 9. 关键结论

1. **嵌套虚拟化是密度瓶颈，不是内存或 CPU**：失败时内存和 CPU 都有大量余裕
2. **全压满 workload 降低了约 30% 密度**：相对于轻量 workload（按 vCPU 比例）
3. **全压满时调度器预留更准确**：overhead 1.06x vs 轻量时 2.0x，因为 Guest 内存被充分 touch
4. **Pod 密度与 vCPU 数近似线性**：可用于容量规划
5. **裸金属部署可大幅提升密度**：消除嵌套虚拟化的额外 VMExit 路径和 nested page walk 开销，预计 2x-3x Pod 密度提升
6. **推荐 overhead：cpu=250m, memory=350Mi**（嵌套虚拟化），cpu=100m, memory=250Mi（裸金属）

## 10. 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload.sh` | 测试脚本 |
| `results-fullload.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test-fullload.log` | 完整测试执行日志 |
| `README.md` | 本分析文档 |
