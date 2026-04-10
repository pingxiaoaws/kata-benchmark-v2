# Kata Containers 运行时开销分析与 Pod Overhead 配置指南

> **适用场景**: 在 Amazon EKS 上使用 Kata Containers (kata-qemu) 实现 Pod 级 VM 隔离的生产环境
> **测试环境**: EKS 1.34, us-west-2, m8i.4xlarge (16 vCPU / 64 GiB) & r8i.2xlarge (8 vCPU / 64 GiB)
> **运行时**: kata-qemu (QEMU + Kata Agent), 对比基准: runc (containerd 2.1.5)
> **日期**: 2026-04-04 ~ 2026-04-07

---

## 1. 核心问题

Kata Containers 通过在每个 Pod 内启动一个轻量级 VM（microVM）来提供硬件级隔离。但这引入了一个关键问题：

> **每个 Kata Pod 的 VM 基础设施（QEMU 进程 + Guest 内核 + virtio 设备）会消耗额外的 CPU 和内存，而 Kubernetes 默认对此完全不可见。**

这意味着：
- `kubectl top pod` 报告的内存为 **0**（cgroup 无法感知 VM 开销）
- Scheduler 按容器 request 调度，**不知道每个 Pod 还有 ~200 MiB 的隐性内存消耗**
- 在高密度部署时，可能导致节点内存耗尽和 OOM Kill

本文档基于三组系统性测试，量化这些开销并给出生产配置建议。

---

## 2. 运行时性能开销（Test 6）

### 测试方法
在同一节点（m8i.4xlarge）上，分别使用 runc、kata-qemu、kata-clh 运行相同工作负载，对比性能差异。

### 2.1 计算与内存：几乎无损

| 维度 | runc | kata-qemu | 开销 |
|------|------|-----------|------|
| CPU 吞吐量 (sysbench, 4 线程) | 5,161 events/s | 5,110 events/s | **< 1%** |
| 内存带宽 (sysbench, 4 线程) | 59,431 MiB/s | 60,492 MiB/s | **无损** |
| Host CPU 额外消耗 | 1.0% | 1.0% | **无差异** |

**结论**: 在纯计算和内存密集型工作负载下，Kata 的嵌套虚拟化开销可忽略不计。得益于 Intel VT-x 硬件加速，L2 VM 内的计算性能接近原生。

### 2.2 网络：显著衰减

| 指标 | runc | kata-qemu | 开销 |
|------|------|-----------|------|
| Pod 间吞吐量 | 64.1 Gbps | 31.9 Gbps | **-50%** |
| Pod 间延迟 | 0.06 ms | 0.80 ms | **+13x** |

**原因**: 每个网络包需要经过 `VM exit → host virtio-net → tap 设备 → veth → 目标 Pod` 的完整路径，引入了额外的上下文切换和数据拷贝。

**建议**: 对延迟敏感的微服务通信（如 gRPC 调用 < 1ms SLA）需要评估是否适合 Kata 隔离，或考虑将强关联服务放在同一 VM 内。

### 2.3 磁盘 I/O：需注意 virtiofs 缓存效应

| 指标 | runc | kata-qemu | 说明 |
|------|------|-----------|------|
| 顺序写 (fio, direct=1) | 128 MB/s | 2,210 MB/s | ⚠️ 非真实对比 |
| 随机读写 (fio, direct=1) | 1,543 IOPS | 23,562 IOPS | ⚠️ 非真实对比 |

> **重要说明**: Kata VM 内的 `O_DIRECT` 标志被 virtiofs 缓存层拦截，数据实际写入 host 内存而非磁盘。因此上表中 kata 的"高性能"是缓存命中的结果，**不代表真实持久化 I/O 性能**。生产环境如需可靠的持久化写入，应通过 CSI 驱动挂载 EBS PVC。

### 2.4 性能开销总览

```
┌─────────────────────────────────────────────────┐
│           Kata Containers 性能开销图谱           │
├─────────────┬───────────┬───────────────────────┤
│  CPU 计算   │   < 1%    │  ✅ 可忽略            │
│  内存带宽   │   < 5%    │  ✅ 可忽略            │
│  网络吞吐   │   -50%    │  ⚠️ 需评估场景        │
│  网络延迟   │   +13x    │  ⚠️ 延迟敏感需关注    │
│  磁盘 I/O   │  依赖存储  │  📌 建议挂 EBS PVC    │
│  Host CPU   │   < 1%    │  ✅ 可忽略            │
└─────────────┴───────────┴───────────────────────┘
```

---

## 3. VM 内存开销画像（Test 7 & Test 9）

### 测试方法
部署 idle pause 容器（最小化应用干扰），通过 host 级指标精确测量每个 Kata Pod 的 VM 内存开销。Test 7 测试 kata-qemu，Test 9 测试 kata-clh，使用相同方法和节点。

### 3.1 单 Pod 内存开销

| 指标 | runc | kata-qemu | kata-clh |
|------|------|-----------|----------|
| Host MemAvailable 变化 | ~4 MiB | **~204 MiB** | **~167 MiB** |

kata-clh 比 kata-qemu 轻 18%，但每个 Pod 仍有 167 MiB 的不可见内存消耗。

### 3.2 VMM 进程内存分解

| 组件 | kata-qemu (QEMU) | kata-clh (Cloud Hypervisor) | 说明 |
|------|------------------|----------------------------|------|
| RssAnon (堆) | 16 MiB | **1.3 MiB** (-92%) | VMM 自身状态、设备模拟 |
| RssFile (库映射) | 84 MiB | **3.7 MiB** (-96%) | 二进制 + 共享库 |
| RssShmem (Guest RAM) | 168 MiB | **148 MiB** (-12%) | VM 实际内存 |
| **VmRSS 合计** | **~269 MiB** | **~150 MiB** (-44%) | |

```
kata-qemu (QEMU):
┌──────────────────────────────────────┐
│  RssShmem  168 MiB (62%)            │  Guest RAM
│  RssFile    84 MiB (31%)            │  QEMU 二进制 + glib/pixman 等
│  RssAnon    16 MiB ( 6%)            │  堆、设备状态、vCPU 线程栈
└──────────────────────────────────────┘

kata-clh (Cloud Hypervisor):
┌──────────────────────────────────────┐
│  RssShmem  148 MiB (97%)            │  Guest RAM
│  RssFile   3.7 MiB ( 2%)            │  静态编译 Rust 二进制
│  RssAnon   1.3 MiB ( 1%)            │  极小的堆
└──────────────────────────────────────┘
```

CLH 进程自身极小（Rust 静态编译 + 仅 virtio 设备），但 Guest RAM 占主体，因此 per-pod 总开销差距缩小到 18%。

> **为什么 VmRSS ≠ MemAvailable delta?**
> RssFile 是磁盘映射的共享库，Linux 内核可随时回收，MemAvailable 不将其计为"已消耗"。MemAvailable delta 更能反映对调度器有意义的**真实不可回收消耗**。

### 3.3 Kubernetes 对 VM 开销完全不可见

| 工具 | runc Pod | kata-qemu Pod | kata-clh Pod |
|------|----------|---------------|--------------|
| `kubectl top pod` | 正常报告 | **报告 0** | **报告 0** |
| Pod cgroup `memory.current` | 0.47 MiB | **0 bytes** | **0 bytes** |
| 调度器 request 计算 | 准确 | **严重低估** | **严重低估** |

**根因**: QEMU / cloud-hypervisor 进程均运行在容器 cgroup 的计账范围之外。两种 VMM 都存在相同的 cgroup 盲区，都需要 Pod Overhead。

### 3.4 开销特征：固定税，线性扩展

**不随应用内存变化（固定开销）：**

| 应用内存压力 (stress-ng) | kata-qemu 净开销 | kata-clh 净开销 |
|--------------------------|-----------------|----------------|
| 0 MiB | 231 MiB | 192 MiB |
| 256 MiB | 200 MiB | 172 MiB |
| 512 MiB | 224 MiB | 191 MiB |
| 1,024 MiB | 255 MiB | 222 MiB |
| **平均** | **~228 MiB** | **~194 MiB** |

**随 Pod 数量线性增长（无 VM 间共享）：**

| Pod 数量 | kata-qemu Per-Pod | kata-clh Per-Pod |
|----------|-------------------|-----------------|
| 1 | 208 MiB | 175 MiB |
| 2 | 213 MiB | 171 MiB |
| 4 | 210 MiB | 170 MiB |
| 8 | **207 MiB** | **167 MiB** |

每个 Kata VM 完全独立——不存在内核页面去重或 KSM 共享。N 个 Pod = N × 固定开销。kata-clh 每 Pod 节省 ~40 MiB。

---

## 4. 解决方案：Pod Overhead（Test 8 & Test 10）

### 4.1 什么是 Pod Overhead？

Kubernetes 从 v1.18 引入、v1.24 GA 的 [Pod Overhead](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/) 机制，允许在 **RuntimeClass** 中声明运行时本身的资源消耗：

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    memory: "250Mi"
    cpu: "100m"
```

### 4.2 工作原理

```
                     用户定义                    Kubernetes 自动计算
                 ┌──────────────┐           ┌──────────────────────────┐
                 │  Container   │           │  Effective Request       │
                 │  Request:    │     +     │  (调度器实际使用的值)      │
                 │  128Mi / 50m │           │  = 128Mi+250Mi / 50m+100m│
                 └──────────────┘           │  = 378Mi / 150m          │
                 ┌──────────────┐           └──────────────────────────┘
                 │  Overhead:   │
                 │  250Mi / 100m│  ← 由 RuntimeClass 定义,
                 └──────────────┘    Admission Controller 自动注入到 Pod spec
```

**影响范围：**
- ✅ Scheduler 调度决策（effective request = container request + overhead）
- ✅ ResourceQuota 计算
- ✅ Kubelet eviction 排序
- ⚠️ Pod cgroup limits（kubelet 将 limits + overhead 写入 cgroup 上限，但 kata 的 QEMU 进程运行在 cgroup 之外，实际不受此限制约束）
- ❌ `kubectl top pod`（读取 cgroup 实时用量，kata-qemu 的 QEMU 进程不在 cgroup 内，仍报 0）

### 4.3 验证：调度器可见性提升 ~3 倍

在同一节点（r8i.2xlarge, 8 vCPU / 64 GiB）上部署 10→50 个 kata-qemu Pods，对比有无 Overhead：

| Pod 数量 | 无 Overhead (调度器认为) | 有 Overhead (调度器认为) | Running | 实际 Host 消耗 |
|----------|------------------------|------------------------|---------|---------------|
| 10 | 1,430 Mi | 3,930 Mi (2.75x) | 10 | ~2,000 MiB |
| 20 | 2,710 Mi | 7,710 Mi (2.84x) | 20 | ~4,100 MiB |
| 30 | 3,990 Mi | **11,490 Mi (2.88x)** | 30 | **~6,200 MiB** |
| 40 | 5,270 Mi | 15,270 Mi (2.90x) | 34~35 | ~8,300 MiB |
| 50 | 6,550 Mi | **19,050 Mi (2.91x)** | 40 | ~8,300 MiB* |

> \* target=40 和 target=50 的实际 Host 消耗接近，因为 CPU 瓶颈导致 running 数量饱和（34→40），新增 pod 极少，MemAvailable 基本不变。

**解读 30 Pods 数据：**
- **无 Overhead**: 调度器认为只用了 3,990 Mi（实际 6,200 MiB），**低估 36%** → 继续过度调度
- **有 Overhead**: 调度器认为用了 11,490 Mi（实际 6,200 MiB），**安全侧高估** → 保守调度，防止 OOM

> 为什么"高估"是正确方向？内存是**不可压缩资源**--低估会导致 host OOM Kill（不可恢复），高估只是损失少量可调度容量（可接受的代价）。

### 4.4 内存压力测试：零 OOM

配置 Overhead 后，部署 25 个 stress-ng Pods（每个分配 256 MiB 内存）：

| Pod 数量 | Host MemAvailable | 调度器记录 | OOM 事件 |
|----------|------------------|-----------|---------|
| 5 | 58,879 MiB | 2,680 Mi | **0** |
| 10 | 56,492 MiB | 5,210 Mi | **0** |
| 15 | 54,142 MiB | 7,740 Mi | **0** |
| 20 | 51,768 MiB | 10,270 Mi | **0** |
| 25 | 49,407 MiB | 12,800 Mi | **0** |

全程零 OOM，调度器正确追踪了 VM 开销 + 应用内存的总消耗。

### 4.5 kata-clh 验证（Test 10）

对 kata-clh 执行了相同的验证流程（overhead: 200Mi / 100m）：

**调度器可见性对比（30 pods）：**

| | kata-qemu (Test 8) | kata-clh (Test 10) |
|---|-------|-------|
| 无 Overhead 调度器认为 | 3,990 Mi | 3,990 Mi |
| 有 Overhead 调度器认为 | 11,490 Mi (2.88x) | 9,990 Mi (2.50x) |
| stress-ng 25 pods OOM | 0 | **0** |
| Scale 50 failed pods | 0 | **3-4** ⚠️ |

**两个 VMM 的 Pod Overhead 均验证通过**——admission controller 注入、scheduler 计算、stress-ng 压力测试全部正常。

⚠️ **kata-clh 稳定性注意**: 在 40-50 pods 高密度场景下，kata-clh 出现 3-4 个 failed pods（非 OOM，而是 VM 启动失败），kata-qemu 无此问题。

---

## 5. Overhead 值推导过程

### Memory: 250Mi

基于 6 组独立测试的实测数据：

| 测试 | 方法 | 测量值 |
|------|------|--------|
| Test 7A | 单 Pod MemAvailable 变化 | 200 - 206 MiB |
| Test 7B | QEMU 进程 RSS（不含可回收映射） | ~185 MiB* |
| Test 7D | 不同内存压力下的净开销 | 200 - 255 MiB |
| Test 7E | 多 Pod 线性验证 (1/2/4/8) | 207 - 213 MiB/pod |
| Test 5b | 10 Pods 大规模验证 | 195 MiB/pod |

> \* 269 MiB RSS - 84 MiB 可回收文件映射 = 185 MiB 不可回收

```
实测中位数:  ~207 MiB
+ 20% 安全缓冲: 207 × 1.2 ≈ 248 MiB → 取整 250 MiB
```

**为什么加 20% 缓冲**: virtiofs 缓存在有 I/O 时会增长；Guest 内核 slab 随工作负载波动；QEMU virtio 设备队列在高负载时消耗更多内存。

### CPU: 100m

| 组件 | 估算消耗 |
|------|---------|
| QEMU vCPU 线程 + 事件循环 (idle) | 20 - 30m |
| virtio-net 网络包处理 | 10 - 20m |
| virtiofs 文件系统操作 | 10 - 20m |
| Guest 定时器中断 (HZ=100) | 5 - 10m |
| **总计** | **~50 - 80m → 取 100m** |

> K8s 官方 Kata 示例使用 250m，但实测 QEMU idle CPU 远低于此。100m 平衡了安全性和 Pod 密度。CPU 密集型工作负载建议提高到 150 - 200m。

---

## 6. 生产配置建议

### 6.1 推荐 RuntimeClass 配置

**kata-qemu（推荐生产使用）：**

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    memory: "250Mi"    # 基于实测 207 MiB + 20% buffer
    cpu: "100m"         # 基于 QEMU idle ~50-80m + buffer
```

**kata-clh（VMM 更轻量，但高负载稳定性需评估）：**

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-clh
handler: kata-clh
overhead:
  podFixed:
    memory: "200Mi"    # 基于实测 167 MiB + 20% buffer
    cpu: "100m"         # CLH idle CPU 与 QEMU 相近
```

**两者对比：**

| | kata-qemu | kata-clh |
|---|-----------|----------|
| Overhead memory | 250Mi | 200Mi |
| 同节点 Pod 密度 | 基准 | **+20%** |
| 高负载稳定性 | ✅ 稳定 | ⚠️ 需验证 |
| 网络性能 | 32 Gbps | 17 Gbps |
| 启动速度 | 4.2s | 3.0s |

### 6.2 容量规划公式

```
每节点最大 Kata Pods ≈ min(
    Allocatable Memory / (Container Memory Request + 250Mi),
    Allocatable CPU / (Container CPU Request + 100m)
)

# Allocatable 已包含 system reserve 的扣除，直接使用即可：
kubectl get node <node> -o jsonpath='{.status.allocatable.memory}'  # 内存
kubectl get node <node> -o jsonpath='{.status.allocatable.cpu}'     # CPU
```

**示例**: m8i.4xlarge (Allocatable: 15800m CPU / 60 GiB Memory)，每 Pod request 512Mi / 200m：

```
Memory: 60 GiB / (512Mi + 250Mi) ≈ 81 pods
CPU:    15800m / (200m + 100m)   ≈ 52 pods
实际上限: ~52 pods (CPU 先饱和)
```

### 6.3 注意事项

| 事项 | 说明 |
|------|------|
| **生效范围** | Overhead 只影响新创建的 Pod；已有 Pod 需重建才能生效 |
| **监控盲区** | `kubectl top pod` 仍不含 VM 开销；需配合 node-level 监控（如 node_memory_MemAvailable） |
| **版本要求** | Pod Overhead 在 K8s v1.24+ 已 GA，无需开启 Feature Gate |
| **定期校准** | Kata 版本升级后 VM 开销可能变化，建议重新测量并调整 overhead 值 |
| **网络密集型** | 如工作负载对网络延迟敏感（< 1ms），需额外评估 Kata 的 13x 延迟增加是否可接受 |

### 6.4 验证 Overhead 是否生效

```bash
# 1. 检查 RuntimeClass 配置
kubectl get runtimeclass kata-qemu -o jsonpath='{.overhead.podFixed}'
# 期望: {"cpu":"100m","memory":"250Mi"}

# 2. 检查 Pod 是否被注入 overhead
kubectl get pod <pod-name> -o jsonpath='{.spec.overhead}'
# 期望: {"cpu":"100m","memory":"250Mi"}

# 3. 检查调度器看到的 effective request
kubectl describe node <node> | grep -A5 "Allocated resources"
# request 列应包含 overhead
```

---

## 7. 总结

| 发现 | 数据支撑 | 影响 |
|------|---------|------|
| Kata CPU/内存计算开销可忽略 | < 1% 差异 | ✅ 适合计算密集型 |
| Kata 网络开销显著 | 吞吐 -50% (qemu) / -74% (clh), 延迟 +13x | ⚠️ 需评估场景 |
| kata-qemu 每 Pod 固定 ~204 MiB 开销 | Test 7 (5 组子测试) | ❌ Scheduler 默认不可见 |
| kata-clh 每 Pod 固定 ~167 MiB 开销 | Test 9 (5 组子测试) | ❌ 同样不可见 |
| VM 开销对 K8s 完全不可见 | 两种 VMM cgroup 均报 0 | ❌ 过度调度风险 |
| CLH 进程比 QEMU 轻 44% | RSS 150 vs 269 MiB | ✅ 但 Pod 密度只提升 ~20% |
| **配置 Pod Overhead 后** | 调度器可见性 +3x | ✅ 防止 OOM，零事故 |

**推荐 Overhead 配置：**

| RuntimeClass | memory | cpu | 适用场景 |
|-------------|--------|-----|---------|
| kata-qemu | **250Mi** | **100m** | 生产首选，稳定性最佳 |
| kata-clh | **200Mi** | **100m** | 追求 Pod 密度，需验证稳定性 |

**一句话建议**: 在生产环境使用 Kata Containers 时，**必须**在 RuntimeClass 中配置 `overhead.podFixed`，否则 Kubernetes 调度器会因不可见的 VM 内存开销而过度调度，最终导致节点 OOM。kata-qemu 和 kata-clh 都存在相同问题。

---

*基于 Amazon EKS 1.34 + Kata Containers (kata-qemu / kata-clh) 实测数据。测试详情见完整报告。*
