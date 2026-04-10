# Kata Containers Pod Overhead — 常见问题 (Q&A)

> 基于 EKS 1.34 + Kata Containers (kata-qemu) 实测数据整理

---

## Q1: Pod Overhead 的 memory 250Mi 和 cpu 100m 是怎么来的？

### Memory: 250Mi

基于 6 组独立测试的实测数据：

| 测试 | 方法 | 测量值 | 说明 |
|------|------|--------|------|
| Test 7A | 单 Pod MemAvailable 变化 | 200–206 MiB | 最直接的调度器视角 |
| Test 7B | QEMU 进程 VmRSS | 269 MiB | 包含可回收的共享库映射 |
| Test 7D | 不同内存压力下的净开销 | 200–255 MiB | 证明 overhead 是固定税 |
| Test 7E | 多 Pod 线性验证 (1/2/4/8) | 207–213 MiB/pod | 无 VM 间内存共享 |
| Test 5b | 10 Pods 大规模验证 | 195 MiB/pod | 批量验证 |

```
实测中位数: ~207 MiB
+ 20% 安全缓冲: 207 × 1.2 ≈ 248 MiB → 取整 250 MiB
```

加 buffer 原因：virtiofs 缓存在有 I/O 时会增长、Guest 内核 slab 随工作负载波动、QEMU virtio 设备队列在高负载时消耗更多内存。**宁可让 scheduler 保守也不要 OOM。**

### CPU: 100m

| 组件 | 估算消耗 |
|------|---------|
| QEMU vCPU 线程 + 事件循环 (idle) | 20–30m |
| virtio-net 网络包处理 | 10–20m |
| virtiofs 文件系统操作 | 10–20m |
| Guest 定时器中断 (HZ=100) | 5–10m |
| **总计** | **~50–80m → 取 100m** |

K8s 官方 Kata 示例用 250m，但实测 QEMU idle CPU 远低于此。100m 平衡了安全性和 Pod 密度。CPU 密集型工作负载建议提高到 150–200m。

---

## Q2: 配置 Overhead 后调度器高估内存，这算优势吗？

以 30 pods 为例：

```
无 overhead → 调度器认为用了  3,990 Mi (低估 36%)  ❌
有 overhead → 调度器认为用了 11,490 Mi (高估 85%)  ✅
实际 host 消耗:              ~6,225 MiB
```

**高估是正确的方向。** 内存是不可压缩资源：

| | 低估 (无 overhead) | 高估 (有 overhead) |
|---|-------------------|-------------------|
| 调度器行为 | "还有 93% 空，继续塞！" | "用了 19%，保守调度" |
| 最终结果 | 过度调度 → **host OOM Kill** | 损失少量可调度容量 → **安全** |

在真实工作负载（非 pause 容器）下，应用内存 + VM overhead 的总量会让调度器的计算更接近真实值，高估幅度会缩小。

---

## Q3: 之前说 CPU 是瓶颈导致 pod crash，为什么测试里没有 crash？

**CPU 瓶颈 ≠ crash。** CPU 瓶颈的表现是 Pod 进入 **Pending 状态**（调度器拒绝调度），不是 crash：

```
target=50 pods:
  running = 40   ← 健康运行
  pending = 10   ← 调度器说"CPU 不够，排队等"
  failed  = 0    ← 没有 crash
  OOM     = 0    ← 没有被 kill
```

CPU 瓶颈是**安全的**——调度器提前拦截。真正危险的是**内存瓶颈不可见**：

| | CPU 不够 | Memory 不够（无 overhead） |
|---|---------|--------------------------|
| 调度器能看到？ | ✅ 是 | ❌ 不能（VM overhead 不计账） |
| 结果 | Pod 进 Pending（安全） | **host OOM killer 随机杀进程** |

Pod Overhead 的价值在于：当 CPU 不再是瓶颈时（比如 CPU request 很小），**内存 overhead 成为最后一道防线**。

---

## Q4: kata-clh 比 kata-qemu 更轻量吗？

设计上 Cloud Hypervisor 更轻（30 万行 Rust vs QEMU 200 万行 C），但实测结果更复杂：

| 维度 | kata-qemu | kata-clh | 赢家 |
|------|-----------|----------|------|
| 启动速度 | 4.2s | 3.0s | CLH |
| 网络吞吐 | 31.9 Gbps | 16.6 Gbps | **QEMU** (差距大) |
| CPU 开销 | < 1% | < 1% | 持平 |
| 高负载稳定性 | ✅ 稳定 | ❌ crash | **QEMU** |

**生产建议**: kata-qemu。CLH 启动更快、进程更小，但网络性能差且高负载下不稳定。

---

## Q5: Benchmark 测试用的什么存储？EBS 还是 EFS？

| 测试场景 | 存储 | 说明 |
|---------|------|------|
| Test 1-5 OpenClaw 部署 | **EBS gp3** (10Gi PVC) | OpenClaw 实例的持久化数据 |
| Test 6C 磁盘性能 (fio) | **容器 ephemeral 文件系统** | fio 写容器内路径，未挂 PVC |
| Test 7/8 pause 容器 | 无存储需求 | 最小化测试 |

⚠️ Test 6C 磁盘数据中 kata 比 runc "快 16 倍" 是假象——Kata VM 内 `O_DIRECT` 被 virtiofs 缓存拦截，数据实际写到了 host 内存而非磁盘。**不代表真实持久化 I/O 性能。**

---

## Q6: VmRSS ≈ VmHWM 是怎么得到的？

来自 QEMU 进程的 `/proc/<pid>/status`：

```
Round 1: VmRSS = 275,204 kB,  VmHWM = 275,204 kB  → 完全相等
Round 2: VmRSS = 275,196 kB,  VmHWM = 275,200 kB  → 差 4 kB
Round 3: VmRSS = 275,052 kB,  VmHWM = 275,052 kB  → 完全相等
```

- **VmRSS**: 当前驻留内存
- **VmHWM** (High Water Mark): 自启动以来 RSS 的历史峰值

两者相等意味着 QEMU 的内存使用是**一条平线**——没有启动瞬间的内存尖峰。这说明用稳态值推导 overhead 是可靠的，不需要额外留启动尖峰的 buffer。

---

## Q7: 为什么 VmRSS (269 MiB) ≠ MemAvailable delta (204 MiB)？

因为它们测的不是同一个东西：

```
VmRSS = RssAnon(16) + RssFile(84) + RssShmem(168) = 269 MiB  ← 进程视角
Delta  = ~204 MiB                                              ← 系统视角
差距   = ~65 MiB ≈ RssFile 的大部分
```

**RssFile (84 MiB)** 是 QEMU 共享库的磁盘映射（mmap），Linux 内核可随时回收这些页面，因此 MemAvailable 不将其计为"已消耗"。

**Pod Overhead 应基于 MemAvailable delta (~207 MiB) 而非 VmRSS (269 MiB)**，因为前者更能反映对调度器有意义的真实不可回收消耗。

---

## Q8: stress-ng 是什么？

`stress-ng` 是 Linux 压力测试工具，可精确控制各类资源消耗：

```bash
# 分配 256MiB 内存并持续读写，持续 60 秒
stress-ng --vm 1 --vm-bytes 256M --vm-keep --timeout 60s

# 跑满 4 个 CPU 核心
stress-ng --cpu 4 --timeout 60s
```

在 Test 7D 中用来验证 VM overhead 是否随应用内存变化（结论：不变，是固定税）。在 Test 8 Phase 5 中用来做内存压力测试（25 pods × 256MiB，零 OOM）。

---

## Q9: Overhead 注入验证为什么看 Pod spec 而不是 RuntimeClass？

**两个都看。** 这是 Pod Overhead 的完整流程：

```
① RuntimeClass 配置 overhead（源头）
   → kubectl get runtimeclass kata-qemu -o jsonpath='{.overhead.podFixed}'
   → {"cpu":"100m","memory":"250Mi"}

② Pod 创建时 Admission Controller 自动注入到 Pod spec
   → kubectl get pod <name> -o jsonpath='{.spec.overhead}'
   → {"cpu":"100m","memory":"250Mi"}

③ Scheduler 使用 effective request = container request + overhead 调度
```

验证注入成功需要检查 Pod spec，因为只有注入后 scheduler 才能看到。

---

## Q10: Pod cgroup limits 和 kubectl top 都看 cgroup，为什么一个受 overhead 影响一个不受？

它们看的是 cgroup 的**不同面**：

| | 设置方 | kata-qemu 的情况 |
|---|-------|-----------------|
| cgroup **limit** (memory.max) | kubelet 写入 | = container limit + overhead = 506Mi ✅ |
| cgroup **usage** (memory.current) | 内核实时统计 | = 0（QEMU 不在 cgroup 里）❌ |
| kubectl top | 读 usage | 报 0 |

kubelet 确实把 cgroup 上限设高了（limit + overhead），但 QEMU 进程运行在 cgroup 之外，实际不受此限制约束。两者不矛盾——一个是"规则设置"，一个是"实时计量"。

---

## Q11: 调度器看的是什么数据？配了 memory request 后能拿到 cgroup 数据吗？

**调度器从不看 cgroup 数据，也不看节点真实内存使用量。** 它用的是纯"账本制"：

```
节点 Allocatable:     60 GiB     ← 固定值
所有 Pod request 之和: 10 GiB     ← 纯加法
剩余可调度:           50 GiB     ← 纯减法
```

各组件的数据来源：

| 组件 | 数据来源 | kata-qemu 时的问题 |
|------|---------|-------------------|
| Scheduler | Pod spec request（账本） | 只看到 128Mi，不知道还有 200Mi VM |
| kubectl top | cgroup 实时用量 | 报 0 |
| Kubelet eviction | cgroup + request | 看不到 VM 真实消耗 |
| Node OOM Killer | /proc/meminfo（内核级） | 能看到，但已经太晚了 |

**Pod Overhead 不是让调度器"看到"cgroup——而是在账本层面把 VM 开销补上去。**

---

## Q12: 为什么 target=40 和 target=50 的 host 内存消耗一样？

因为 **target ≠ running**：

```
target=40 → running=34 → MemAvail=52,978 MiB → 消耗 ~8,283 MiB
target=50 → running=40 → MemAvail=52,988 MiB → 消耗 ~8,273 MiB
```

CPU 瓶颈导致 running 数量饱和（8 vCPU 节点约能跑 40 个 kata pod），target 从 40 提到 50 只多跑了 6 个 pod (34→40)，加上内核 page cache 回收，MemAvailable 基本持平。

---

## Q13: Allocatable Memory - System Reserve 怎么获取？

**Allocatable 已经是减掉 system reserve 之后的值**，直接用即可：

```bash
# Allocatable（可分配给 Pod 的内存）
kubectl get node <node> -o jsonpath='{.status.allocatable.memory}'
# → 63084396Ki (~60 GiB)

# Capacity（物理总内存）
kubectl get node <node> -o jsonpath='{.status.capacity.memory}'
# → 65321984Ki (~64 GiB)

# 差值即 system reserve:
# Capacity - Allocatable = kube-reserved + system-reserved + eviction-threshold
```

容量规划公式直接用 Allocatable：
```
最大 Kata Pods = min(
    Allocatable Memory / (Container Memory Request + 250Mi),
    Allocatable CPU / (Container CPU Request + 100m)
)
```

---

## Q14: "两种 VMM cgroup 均报 0" 是如何检测的？

通过在 host 上直接读取 cgroup v2 的内存计量文件。

### 步骤 1: 获取 Pod UID

```bash
pod_uid=$(kubectl get pod -n bench7 t7c-kata-qemu -o jsonpath='{.metadata.uid}')
# → fed8292e-158d-487d-8508-b3f1fb424e16
```

### 步骤 2: 在 host 上找到 Pod 对应的 cgroup 目录并读取

通过 hostPod（配置了 `hostPID: true` 的特权 Pod）进入目标节点，查找 cgroup v2 的 `memory.current` 文件：

```bash
# 查找 Pod 的 cgroup 路径
find /sys/fs/cgroup -path "*pod${pod_uid}*" -name "memory.current"
# → /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/
#     kubepods-burstable-pod<uid>.slice/memory.current

# 读取当前内存用量
cat /sys/fs/cgroup/.../memory.current
```

### 实际结果

| 运行时 | `memory.current` | 含义 |
|--------|------------------|------|
| runc | 495,616 bytes (0.47 MiB) | ✅ 容器进程 (pause) 的内存，正常 |
| kata-qemu | **0 bytes** | ❌ cgroup 里只有 kata-shim，QEMU 不在里面 |
| kata-clh | **0 bytes** | ❌ 同理，cloud-hypervisor 不在 cgroup 里 |

### 原始数据 (CSV)

```csv
# Test 7C (kata-qemu)
test,runtime,cgroup_memory_current_bytes
7C,runc,495616
7C,kata-qemu,0

# Test 9C (kata-clh)
test,runtime,cgroup_memory_current_bytes
9C,runc,495616
9C,kata-clh,0
```

### 为什么是 0？

`memory.current` 是 cgroup v2 的实时内存计量文件——内核将属于该 cgroup 的**所有进程**的内存用量累加到此。`kubectl top` 和 Metrics Server 最终读的就是这个值。

对于 Kata Pod，cgroup 里只有一个轻量的 `kata-shim` 进程（负责 gRPC 通信），而真正消耗内存的 QEMU / cloud-hypervisor 进程是由 Kata runtime 在 **host 级别 fork 出来的**，不属于 Pod 的 cgroup 层级，因此不被计入。

---

## Q15: Pod Overhead 和 `sandbox_cgroup_only = true` 是不是重叠了？

**不重叠，它们解决的是不同层的问题，必须配合使用：**

| | Pod Overhead | `sandbox_cgroup_only = true` |
|---|---|---|
| **作用层** | Kubernetes 调度器 | Kata 运行时 |
| **解决什么** | 让调度器知道每个 Pod 还需要额外 250Mi/100m，**调度时预留空间** | 让 Kata 把 VMM 进程（QEMU、I/O 线程、Shim）**放进 Pod cgroup 内**，而不是放到不受限的 `/kata_overhead/` |
| **不配的后果** | 调度器低估资源 → 节点过载 → OOM | VMM 跑在 cgroup 外 → 无资源隔离，`kubectl top` 报 0 |

简单说：

- **Pod Overhead** = 告诉 K8s："这个 Pod 要多占 250Mi" → Kubelet 把 Pod cgroup **撑大**
- **`sandbox_cgroup_only = true`** = 告诉 Kata："把 VMM 进程放进这个撑大的 cgroup 里"

如果只配 Pod Overhead 不开 `sandbox_cgroup_only`：调度器算对了，但 VMM 还是跑在 `/kata_overhead/` 不受限 cgroup 里，cgroup 统计还是不准。

如果只开 `sandbox_cgroup_only` 不配 Pod Overhead：Kata 把 VMM 塞进 Pod cgroup，但 cgroup 没有被撑大（只按容器 request 分配），VMM 和容器抢资源 → 性能下降甚至 OOM。

**一个撑伞，一个站进去，缺一不可。**

参考：[Kata Host Cgroup 设计文档](https://github.com/kata-containers/kata-containers/blob/main/docs/design/host-cgroups.md)

---

## Q16: `kubectl top` 报 0 有什么实际影响？

`kubectl top` 报 0 的影响主要在**可观测性和自动扩缩**，但对调度和节点稳定性影响不大：

### 有影响的场景

| 场景 | 影响 |
|------|------|
| **HPA 自动扩缩** | 如果用 `metrics.k8s.io`（即 metrics-server / `kubectl top` 的数据源）做内存型 HPA，永远看到 0 → 永远不会触发扩容 ❌ |
| **运维排查** | `kubectl top pod` 看不到 Kata Pod 真实资源消耗，排障时会误判 |
| **Grafana/Prometheus 面板** | 如果 dashboard 用 `container_memory_working_set_bytes`（来自 cAdvisor/cgroup），Kata Pod 全部显示 0，监控形同虚设 |
| **VPA** | Vertical Pod Autoscaler 基于历史 metrics 推荐 request，数据是 0 就推荐不出合理值 |

### 没影响的场景

| 场景 | 为什么没影响 |
|------|------------|
| **调度器** | 调度器**从来不看** `kubectl top` 的数据，它只做 request 加减法（纯账本制），所以 Pod Overhead 能完全解决调度准确性 |
| **Kubelet eviction** | Kubelet 看的是 node 级别的 `memory.available`（来自 `/proc/meminfo`），不是 Pod cgroup，所以 VMM 吃的内存在 eviction 判断中是可见的 |
| **OOM Killer** | 内核 OOM Killer 看的是整个系统内存压力，不依赖 cgroup 统计 |

### 解决方案

如果依赖 metrics-server 数据做 HPA 或监控，需要换数据源——比如用 node_exporter 的 `node_memory_MemAvailable` 或在 VM 内装 agent 导出 metrics。配合 Q15 中的 `sandbox_cgroup_only = true`，可以让 VMM 进程回到 Pod cgroup 内，从而恢复 `kubectl top` 的准确性。

---

## Q17: K8s Scheduler 调度到底走不走 cgroup？

**完全不走。** Scheduler 是纯"账本制"：

```
Node Allocatable:     60 GiB     ← 固定值（capacity - system-reserved - kube-reserved）
所有 Pod request 之和: 10 GiB     ← 纯加法（从 etcd 读 Pod spec）
剩余可调度:           50 GiB     ← 纯减法
```

各组件的数据来源对比：

| 组件 | 数据来源 | 看不看 cgroup？ |
|------|---------|---------------|
| **Scheduler** | Pod spec request（etcd 账本） | ❌ 完全不看 |
| kubectl top | cgroup 实时用量 | 是（读 cgroup） |
| Kubelet eviction | /proc/meminfo + cgroup | 是（但看 node 级） |
| Node OOM Killer | /proc/meminfo（内核级） | 否（看系统内存压力） |

所以哪怕节点实际内存已经快爆了，只要账本上还有余额，scheduler 照样往上面塞 Pod。反过来，节点实际很空闲但账本满了，新 Pod 就会 Pending。

**Pod Overhead 不是让调度器"看到"cgroup——而是在账本层面把 VM 开销补上去。** 这就是为什么 Pod Overhead 能解决调度准确性问题，而跟 `kubectl top` 报不报 0 完全无关。

---

*整理自 Kata Containers benchmark 测试过程中的实际技术讨论。*
