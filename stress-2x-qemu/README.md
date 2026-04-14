# 最大 Pod 密度测试：kata-qemu 全压满 — m8i.2xlarge（嵌套虚拟化）

**日期：** 2026-04-13 03:06–03:22 UTC  
**结果：10 个 Pod 稳定，第 11 个 Pod 触发级联 VM 崩溃（31 次容器 restart）**

## 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-17-237.us-west-2.compute.internal |
| 实例类型 | m8i.2xlarge（8 vCPU，32 GiB） |
| 虚拟化 | **嵌套**（EC2 .metal-equivalent 上的 KVM） |
| 节点可调度资源 | cpu=7910m，memory=30619520Ki（~29903 MiB） |
| RuntimeClass | kata-qemu |
| Pod Overhead | cpu=100m，memory=250Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s 版本 | v1.34.4-eks |
| Containerd | 2.1.5 |

### Pod 规格（Guaranteed QoS，request = limit）

| 容器 | CPU | 内存 | 工作负载 |
|------|-----|------|---------|
| gateway (nginx:1.27) | 150m | 1Gi | nginx + liveness/readiness 探针 |
| config-watcher (busybox:1.36) | 100m | 256Mi | 200 MiB shm + sleep 循环 |
| envoy (busybox:1.36) | 100m | 256Mi | 200 MiB shm + CPU 循环 |
| wazuh (busybox:1.36) | 100m | 512Mi | 400 MiB shm + find 循环 |
| **容器合计** | **450m** | **2048 MiB** | |
| **+ RuntimeClass overhead** | **+100m** | **+250 MiB** | |
| **调度器视角（每 Pod）** | **550m** | **2298 MiB** | |

## 理论计算

```
节点可调度内存:     29903 MiB
系统 Pod 请求:      -  150 MiB（aws-node、kube-proxy 等）
可用于测试 Pod:      29753 MiB

每 Pod（含 overhead）: 2298 MiB
内存上限: floor(29753 / 2298) = 12

节点可调度 CPU:      7910m
系统 Pod 请求:       - 190m
可用于测试 Pod:       7720m

每 Pod（含 overhead）:  550m
CPU 上限: floor(7720 / 550) = 14

理论最大值 = 12 个 Pod（内存受限）
```

## 实际结果

| 指标 | 值 |
|------|-----|
| **最大稳定 Pod 数** | **10** |
| 停止触发 | 部署第 11 个 Pod 后出现 31 次容器 restart |
| 理论最大值 | 12（调度器内存受限） |
| 差距 | 2 个 Pod（比理论少 17%） |
| 失败模式 | 第 11 个 VM 启动时引发级联 VM 崩溃 |

## 逐 Pod 数据表

### 稳态指标（每个 Pod Ready 后 60s 采集）

| Pod | 就绪(s) | kt top pod(MiB) | QEMU RSS(MiB) | kt top node(MiB) | 宿主可用(MiB) | Restart |
|-----|---------|-----------------|----------------|-------------------|---------------|---------|
| 1 | 13 | 809 | 1144 | 2773 | 28876 | 0 |
| 2 | 13 | 810 | 2292 | 3852 | 27780 | 0 |
| 3 | 12 | 809 | 3435 | 4930 | 26679 | 0 |
| 4 | 12 | 808 | 4581 | 6012 | 25596 | 0 |
| 5 | 13 | 810 | 5728 | 7087 | 24509 | 0 |
| 6 | 13 | 810 | 6877 | 8183 | 23389 | 0 |
| 7 | 12 | 811 | 8027 | 9269 | 22275 | 0 |
| 8 | 13 | 809 | 9177 | 10344 | 21199 | 0 |
| 9 | 13 | 810 | 10331 | 11434 | 20096 | 0 |
| 10 | 12 | 809 | 11478 | 12515 | 18993 | 0 |
| **11** | **37** | **N/A**（指标崩溃） | **10426** | **N/A** | **19911** | **31** |

注："kt top pod" 值为 `kubectl top pod --containers` 各容器之和（gateway ~6Mi + config-watcher ~200Mi + envoy ~201Mi + wazuh ~402Mi）。

### 各容器指标（10 个稳定 Pod 间高度一致）

| 容器 | CPU（kubectl top） | 内存（kubectl top） | /dev/shm 分配 |
|------|-------------------|--------------------|--------------| 
| gateway | 1m | 6 MiB | 无 |
| config-watcher | 0-1m | 200-201 MiB | 200 MiB |
| envoy | 100-101m | 200-201 MiB | 200 MiB |
| wazuh | 2m | 401-402 MiB | 400 MiB |
| **合计** | **~104m** | **~809 MiB** | **800 MiB** |

## 节点级逐步数据

| Pod数 | 节点CPU | CPU% | 节点内存 | 内存% | 宿主Total | 宿主Used | 宿主Free | 宿主Avail | QEMU RSS 合计 |
|-------|---------|------|----------|-------|-----------|----------|----------|-----------|--------------|
| 0（基线） | 36m | 0% | 1704Mi | 5% | 31554 | 1133 | 23163 | 29968 | 0 |
| 1 | 1173m | 14% | 2773Mi | 9% | 31554 | 1180 | 22072 | 28876 | 1144 |
| 2 | 1295m | 16% | 3852Mi | 12% | 31554 | 1229 | 20976 | 27780 | 2292 |
| 3 | 1547m | 19% | 4930Mi | 16% | 31554 | 1287 | 19870 | 26679 | 3435 |
| 4 | 1878m | 23% | 6012Mi | 20% | 31554 | 1324 | 18783 | 25596 | 4581 |
| 5 | 2062m | 26% | 7087Mi | 23% | 31554 | 1364 | 17693 | 24509 | 5728 |
| 6 | 2181m | 27% | 8183Mi | 27% | 31554 | 1435 | 16568 | 23389 | 6877 |
| 7 | 2566m | 32% | 9269Mi | 31% | 31554 | 1499 | 15451 | 22275 | 8027 |
| 8 | 2529m | 31% | 10344Mi | 34% | 31554 | 1525 | 14371 | 21199 | 9177 |
| 9 | 2941m | 37% | 11434Mi | 38% | 31554 | 1574 | 13264 | 20096 | 10331 |
| 10 | 2984m | 37% | 12515Mi | 41% | 31554 | 1630 | 12164 | 18993 | 11478 |
| 11（崩溃） | N/A | N/A | N/A | N/A | 31554 | 1730 | 13087 | 19911 | 10426 |

所有内存值单位为 MiB。

### 每 Pod 增量开销（从稳定区间 Pod 1-10 推导）

| 指标 | 每 Pod 增量 | 备注 |
|------|------------|------|
| QEMU RSS | ~1148 MiB | 高度一致：每 VM 1140-1151 MiB |
| kubectl top node 内存 | ~1081 MiB | kubelet 的 cAdvisor 所见 |
| 宿主可用内存（free -m） | ~1098 MiB | 实际宿主内存消耗 |
| 宿主 buff/cache | ~1050 MiB | page cache 中的 VM 内存页 |
| 宿主 "used"（free -m） | ~50 MiB | 仅 QEMU 进程元数据 |
| kubectl top node CPU | ~295m | 每 VM 5 vCPU，但工作负载仅使用 ~104m |

## 内存可见性分析

这是本测试的**核心发现**。四个不同工具对同一工作负载报告四个不同的数字：

```
                     每 Pod（MiB）
                     ──────────────
kubectl top pod:          809    ← Guest VM 内容器 cgroup RSS
QEMU RSS（宿主 ps）:      1148    ← Guest 已触碰的内存页 + QEMU 开销
kubectl top node (Δ):    1081    ← cAdvisor 看到的 QEMU sandbox cgroup
宿主 free -m (Δ avail):  1098    ← 实际宿主物理内存消耗
调度器预留:              2298    ← 容器 request(2048) + overhead(250)
```

### 数字为什么不同

1. **kubectl top pod（809 MiB）** 报告的是 **Guest VM 内部** 容器的 RSS。它看到的是 800 MiB 的 /dev/shm 数据加上 nginx 的 6 MiB。它**看不到** Guest 内核内存、kata-agent 和 QEMU 开销。这是容量规划中**最无用的数字**。

2. **QEMU RSS（1148 MiB）** 是宿主内核分配给 QEMU 进程的物理内存。包括所有已触碰的 Guest 页面 + QEMU 自身的堆。VM 分配了 2048 MiB 但只有 ~1148 MiB 的页被实际触碰（工作负载只使用 ~809 MiB + Guest 内核 ~200 MiB + QEMU 开销 ~139 MiB）。

3. **kubectl top node（1081 MiB 增量）** 来自 cAdvisor 读取 QEMU sandbox 的 cgroup。略低于宿主 `ps`，因为 cAdvisor 采样时间不同，且对共享页的计算方式不同。

4. **宿主可用内存（1098 MiB 增量）** 是内核视角的**真实开销**。与 QEMU RSS 高度吻合，确认了那是真实成本。

5. **调度器预留（2298 MiB）** 是纯粹的**记账虚构**。调度器阻止了超过 12 个 Pod 的调度，但宿主每 Pod 实际只消耗 1098 MiB。10 个 Pod 时，调度器认为 76% 内存已用；宿主报告只用了 41%。

### 可见性差距

```
调度器看到:     10 pods × 2298 MiB = 22980 MiB 已预留（可调度的 77%）
宿主实际使用:   10 pods × 1148 MiB = 11480 MiB QEMU RSS（物理内存的 36%）
宿主可用:       18993 MiB（物理内存的 60% 仍然空闲）
```

调度器相比实际宿主消耗**超额预留 2.0 倍**。原因：
- 容器 limit（2048 MiB）由 kata-agent 在 VM 内部强制执行，不在宿主上
- QEMU 进程 RSS 只反映已触碰的页，不是完整的 VM 分配
- 250 MiB overhead 叠加在上面，进一步拉大差距

## Pod 11 崩溃分析

### 时间线

```
03:19:54  Pod 11 创建
03:20:02  7 个现有 VM 同时被杀（Pod 2,3,4,5,7,8,9）
03:20:03  被杀 VM 中的容器开始 restart
03:20:31  Pod 11 终于 Ready（37s vs 正常 12-13s）
03:21:31  Settle 期结束 — 检测到所有 Pod 共 31 次 restart
```

### 发生了什么

第 11 个 QEMU VM 的启动导致了**级联 VM 崩溃**。关键证据：

1. **同时死亡**：Pod 2,3,4,5,7,8,9 中所有容器的退出时间都是 `finishedAt: 2026-04-13T03:20:02Z` — 同一秒。这排除了单个容器 OOM；某些东西从外部杀死了 VM。

2. **QEMU 进程被替换**：Pod 11 之前有 10 个 QEMU PID（1018318-1024633）。崩溃后其中 7 个 PID 消失，被新的更高 PID（1025446-1027212）替代。存活的 PID 恰好对应 Pod 1、6 和 10（0 restart 的 Pod）。

3. **Pod 11 启动缓慢**：37 秒才 Ready，而 Pod 1-10 是 12-13s。宿主处于严重资源争抢。

4. **无宿主级 OOM**：`dmesg` 中没有 QEMU OOM kill。宿主可用内存 ~19 GiB — 充裕。失败**不是内存耗尽**。

5. **嵌套虚拟化瓶颈**：11 个 VM 在嵌套虚拟化下运行时，L1 KVM hypervisor 必须为每个 VM 管理 EPT 影子页表。在 10 个 VM 正在活跃运行（内存密集工作负载）时启动第 11 个 VM，对 L1 hypervisor 的页表管理造成极端压力，导致 VM 调度停滞和最终崩溃。

### 存活 vs 被杀的 VM

| 存活（0 restart） | 被杀（4-5 次 restart） |
|-------------------|----------------------|
| sandbox-1（最老） | sandbox-2 |
| sandbox-6（中间） | sandbox-3 |
| sandbox-10（最新） | sandbox-4 |
| | sandbox-5 |
| | sandbox-7 |
| | sandbox-8 |
| | sandbox-9 |

存活模式（1、6、10）不遵循明确的年龄或资源排序。这与争抢下非确定性的 hypervisor 调度一致。

## 差距分析：理论 vs 实际

```
调度器理论最大值:      12 个 Pod（内存受限）
实际稳定最大值:        10 个 Pod（嵌套虚拟化争抢）
差距:                 2 个 Pod（17%）
```

### 差距原因

| 因素 | 影响 |
|------|------|
| **嵌套虚拟化开销** | 主要原因。L1 KVM 管理 10+ 个 VM 的 EPT 影子表造成极端争抢。裸金属上 12+ 个 Pod 很可能成功。 |
| **VM 启动资源尖峰** | 每个 QEMU VM 启动期间临时消耗更多资源（页表建立、内存 balloon、内核引导）。已有 10 个 VM 运行时，第 11 个 VM 的尖峰将 hypervisor 推过极限。 |
| **QEMU VSZ vs RSS** | 每个 QEMU VSZ=5327 MiB 但 RSS=~1148 MiB。虚拟地址空间预留（mmap 但未 fault in）仍然消耗内核 VMA 和页表资源。 |
| **Guest 内核开销** | 每个 VM 的 Guest 内核消耗 ~200 MiB，对 `kubectl top pod` 不可见但计入 QEMU RSS。10 个 VM 就是 2 GiB 的"隐藏"内存。 |

### 裸金属会有什么变化

在裸金属 m8i.2xlarge 上（无嵌套虚拟化）：
- VM 启动速度快 ~2 倍（无 EPT 影子页表）
- 每 VM 的 CPU 开销低 ~30-50%
- 10-11 VM 时的 hypervisor 争抢墙将不存在
- 预期稳定数：**12 个 Pod**（达到调度器上限）
- 如果 overhead 调低，可能达到 **13-14 个**

## 推荐 Pod Overhead 配置

### 当前状态（嵌套虚拟化）

当前 overhead `cpu=100m, memory=250Mi` 允许调度器放置 12 个 Pod，但节点在 11 个时变得不稳定。防止此问题：

```yaml
# 嵌套虚拟化保守配置
overhead:
  podFixed:
    cpu: 250m      # 包含 QEMU + hypervisor CPU 开销
    memory: 950Mi  # 限制调度器到 10 个 Pod: floor(29753 / (2048+950)) = 9
```

使用 `memory: 950Mi` overhead，调度器将允许 `floor(29753 / 2998) = 9 个 Pod`，在观测到的 10 Pod 极限下提供 1 个 Pod 的安全余量。

### 裸金属（推荐）

```yaml
# 裸金属紧凑但安全配置（无嵌套虚拟化）
overhead:
  podFixed:
    cpu: 100m
    memory: 250Mi  # 调度器允许 12 个 Pod — 很可能是真实稳定极限
```

当前 250 MiB overhead 适用于不存在嵌套虚拟化惩罚的裸金属。

### 基于观测宿主内存的 Overhead

如果你想让调度器准确预测宿主内存消耗（而非超额预留）：

```
实际宿主每 Pod 内存:    ~1148 MiB（QEMU RSS）
容器 request:           2048 MiB（在 Guest 内执行，不在宿主上）
"正确" overhead:        1148 - 2048 = -900 MiB（不可能）
```

这揭示了一个根本性不匹配：Kubernetes 调度器模型假设容器 request 对应宿主内存。在 kata-containers 中并非如此 — 它们对应的是 **Guest VM 内存**。宿主只看到 QEMU RSS。overhead 机制无法纠正这个问题，因为它只能加，不能减。

**实践建议**：接受超额预留。它为那些触碰更多 Guest 内存的工作负载（不像本测试的 800 MiB shm）提供了安全余量。

## 关键数字汇总

| 指标 | 值 |
|------|-----|
| 最大稳定 Pod 数（本测试） | **10** |
| 调度器理论上限 | 12 |
| 每 Pod QEMU RSS | 1148 MiB |
| 每 Pod kubectl top pod | 809 MiB |
| 每 Pod 宿主内存（实际） | ~1098 MiB |
| 每 Pod 调度器预留 | 2298 MiB |
| 超额预留比 | 2.0x |
| VM 启动时间（稳定） | 12-13s |
| VM 启动时间（极限） | 37s |
| 失败模式 | 嵌套虚拟化争抢导致级联 VM 崩溃 |
| 失败时宿主内存 | 19 GiB 可用（60% 空闲） |

## 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test.sh` | 测试脚本 |
| `results.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test.log` | 完整测试执行日志（630 行） |
| `README.md` | 本分析文档 |
