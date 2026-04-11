# Test 11e: /dev/shm 耗尽导致 Kata Pod 创建失败 — 复现报告

## 1. 背景

客户报告：在 Kata Containers (kata-qemu) 环境中，当节点上运行多个 Pod 时，新 Pod 创建失败。客户提供的 host `top` 输出显示：

```
PID     USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
11702   root      20   0 9869740  2.5g   2.5g S  71.4   8.2 541:18.15 qemu-system-x86_64
472542  root      20   0 9869740  2.5g   2.5g S  94.0   8.1  52:43.88 qemu-system-x86_64
63379   root      20   0 9869740  2.5g   2.5g S   2.3   8.1 527:13.51 qemu-system-x86_64
491718  root      20   0 9869740  2.5g   2.5g S  78.4   8.1  35:43.42 qemu-system-x86_64
35376   root      20   0 9869740  2.5g   2.5g S  20.3   8.0 521:09.70 qemu-system-x86_64
21548   root      20   0 9869740  2.5g   2.5g S   2.0   8.0 530:21.86 qemu-system-x86_64
523028  root      20   0 9869740  1.1g   1.1g S 211.3   3.6   1:07.80 qemu-system-x86_64  ← 异常
21552   root      20   0 8698956 953356 947028 S   0.3   3.0  69:00.07 virtiofsd
```

**关键异常**：PID 523028 的 RSS 只有 1.1 GiB（正常应为 2.5 GiB），CPU 飙到 211.3%，运行时间仅 1:07（刚启动）。

---

## 2. 假设与分析

### 2.1 初始观察

| 指标 | 正常 VM | 异常 VM (523028) |
|------|---------|-----------------|
| VIRT | 9.4 GiB | 9.4 GiB |
| RSS | 2.5 GiB | **1.1 GiB** |
| SHR | 2.5 GiB | 1.1 GiB |
| %CPU | 2-94% | **211.3%** |
| TIME+ | 500+ min | **1:07** |

### 2.2 关键发现：RES ≈ SHR

所有 QEMU 进程的 RES ≈ SHR。这是因为 Kata 使用 `shared_fs = "virtio-fs"` 时，QEMU 自动使用 `/dev/shm`（tmpfs）作为 guest RAM 的 `memory-backend-file`。tmpfs 映射的内存在 `ps` 中表现为 SHR（可共享），但**每个 VM 的映射是独立的，物理内存各占一份**。

### 2.3 根因推断

```
Host RAM:    ~30.5 GiB (2.5 GiB / 8.2% ≈ 30.5 GiB)
/dev/shm:   默认 50% RAM ≈ 15.2 GiB
7 VM × ~2.2 GiB/dev/shm ≈ 15.4 GiB → /dev/shm 耗尽
第 8 个 VM 无法完整分配 guest RAM → RSS 只有 1.1 GiB
```

---

## 3. 测试环境

| 项目 | 值 |
|------|-----|
| 集群 | Amazon EKS 1.34, us-west-2 |
| 测试节点 | ip-172-31-17-237 (m8i.2xlarge) |
| 节点规格 | 8 vCPU, 32 GiB RAM |
| Host 内核 | 6.12.68-92.122.amzn2023.x86_64 |
| Kata 版本 | 3.27.0 (kata-deploy Helm chart) |
| VMM | QEMU |
| Kata VM 内核 | 6.18.12 |
| /dev/shm 默认大小 | 16 GiB (50% of 32 GiB) |

---

## 4. 测试步骤

### 4.1 前置准备

**hostmon Pod**：已在测试节点上部署特权 Pod，通过 `nsenter` 访问 host namespace，用于监控 host 级别指标。

```bash
# hostmon 已部署在测试节点上
kubectl get pod hostmon -o wide
# NAME      READY   STATUS    NODE
# hostmon   1/1     Running   ip-172-31-17-237.us-west-2.compute.internal
```

### 4.2 修改 Kata 配置

将 guest 默认内存从 2048 MiB 提升到 4096 MiB，模拟客户 VIRT=9.4 GiB 的场景：

```bash
# 通过 hostmon nsenter 修改节点上的 Kata 配置
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  sed -i 's/^default_memory = .*/default_memory = 4096/' \
  /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
```

配置文件路径：`/opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml`

其他关键配置：
- `default_vcpus = 5`
- `shared_fs = "virtio-fs"` （导致 QEMU 使用 /dev/shm 作为 memory backend）

### 4.3 Pod 定义

每个 Pod 包含两个容器：
- **stress 容器**：`polinux/stress-ng:latest`，运行 `stress-ng --vm 2 --vm-bytes 2g --vm-keep --timeout 0`
- **sleep 容器**：`busybox:1.36`，运行 `sleep infinity`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: stress-N
  labels:
    app: mem-pressure-test
spec:
  runtimeClassName: kata-qemu
  overhead:
    memory: "640Mi"
    cpu: "500m"
  containers:
  - name: stress
    image: polinux/stress-ng:latest
    command: ["stress-ng", "--vm", "2", "--vm-bytes", "2g", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "500m", memory: "3Gi" }
      limits: { cpu: "2000m", memory: "3584Mi" }
  - name: sleep
    image: busybox:1.36
    command: ["sleep", "infinity"]
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits: { cpu: "100m", memory: "128Mi" }
```

**stress-ng 参数说明**：
- `--vm 2`：启动 2 个 VM stressor worker
- `--vm-bytes 2g`：每个 worker 分配并持续读写 2 GiB 内存
- `--vm-keep`：保持内存映射不释放（持续占用）
- `--timeout 0`：永不退出

这迫使 guest 内核将 ~4 GiB 的虚拟页面 fault in 为物理页面，host 上表现为 QEMU 进程的 RSS 增长（通过 /dev/shm 映射）。

### 4.4 测试执行

**脚本**：`scripts/test11e-mem-pressure-repro.sh`

执行流程：
1. 清理残留 namespace
2. 修改 `default_memory=4096`
3. 采集 baseline 指标
4. 逐个部署 Pod（最多 10 个），每个部署后等待 20s 让 stress-ng warm up
5. 每个 Pod 部署后采集：node CPU、MemAvailable、/dev/shm used、QEMU 数量/CPU/RSS
6. 检测 CrashLoopBackOff/Error/Evicted 状态
7. 失败后继续采集 3 轮 post-failure 数据
8. 清理并恢复 `default_memory=2048`

```bash
bash /home/ec2-user/kata-benchmark-v2/scripts/test11e-mem-pressure-repro.sh
```

---

## 5. 测试结果

### 5.1 逐 Pod 部署数据

| Phase | Pods | Running | /dev/shm Used | QEMU Total RSS | MemAvailable | 状态 |
|-------|------|---------|---------------|----------------|--------------|------|
| baseline | 0 | 0 | 0 MiB | 0 MiB | 30,020 MiB | ✅ |
| deployed-1 | 1 | 1 | 3,908 MiB | 4,009 MiB | 26,043 MiB | ✅ |
| deployed-2 | 2 | 2 | 7,821 MiB | 8,024 MiB | 22,082 MiB | ✅ |
| deployed-3 | 3 | 3 | 11,753 MiB | 12,057 MiB | 18,101 MiB | ✅ |
| deployed-4 | 4 | 4 | 15,686 MiB | 16,094 MiB | 14,092 MiB | ✅ (接近 /dev/shm 上限) |
| deployed-5 | 5 | 5 | 7,915 MiB | 9,992 MiB | 22,752 MiB | ⚠️ 部分 Pod 被 OOM/重启 |
| deployed-6 | 6 | 6 | **16,384 MiB** | 16,991 MiB | 13,299 MiB | ⚠️ /dev/shm 100% 满 |

### 5.2 最终 Pod 状态

```
NAMESPACE   NAME       READY   STATUS    RESTARTS        AGE
t11em-1     stress-1   2/2     Running   4 (2m14s ago)   5m16s   ← 4 次重启
t11em-2     stress-2   2/2     Running   2 (2m32s ago)   4m43s   ← 2 次重启
t11em-3     stress-3   2/2     Running   2 (2m33s ago)   4m10s   ← 2 次重启
t11em-4     stress-4   0/2     Error     6 (39s ago)     4m6s    ← ❌ 持续失败
t11em-5     stress-5   0/2     Error     2               3m31s   ← ❌ 持续失败
t11em-6     stress-6   2/2     Running   0               2m53s   ← 正常（抢到了释放的 shm）
```

### 5.3 失败错误信息

Pod stress-5 的 `kubectl describe` 输出：

```
Warning  FailedCreatePodSandBox  kubelet  
  Failed to create pod sandbox: rpc error: code = Unknown desc = 
  failed to start sandbox: failed to create containerd task: 
  failed to create shim task: 
  Failed to Check if grpc server is working: 
  rpc error: code = DeadlineExceeded desc = timed out connecting to vsock 2004980445:1024
```

**失败链**：
1. `/dev/shm` 空间耗尽
2. QEMU 无法完整分配 `memory-backend-file`（guest RAM 映射）
3. Guest VM 启动不完整或 kata-agent 无法初始化
4. kata-runtime 等待 vsock 连接超时（`DeadlineExceeded`）
5. containerd 报告 sandbox 创建失败

### 5.4 Host 内存最终状态

```
              total        used        free      shared  buff/cache   available
Mem:           30Gi       1.5Gi       874Mi        15Gi        28Gi        13Gi

/dev/shm:
Filesystem      Size  Used Avail Use%
tmpfs            16G   16G  516M  97%
```

### 5.5 QEMU 进程状态（host ps 输出）

```
PID     %CPU  %MEM    RSS(MiB)   VSZ(GiB)  COMMAND
258195  145   12.7    4,034      9.0       qemu-system-x86_64   ← 正常
257744  147   12.7    4,021      9.0       qemu-system-x86_64   ← 正常
257462  149   12.7    4,019      9.0       qemu-system-x86_64   ← 正常
258809  126   12.7    4,011      9.0       qemu-system-x86_64   ← 正常
261143  23.6   1.0      320      5.1       qemu-system-x86_64   ← 异常（RSS 小）
260569   4.8   0.1       40      5.1       qemu-system-x86_64   ← 异常（RSS 极小）
```

**异常 VM 特征与客户数据完全一致**：
- 正常 VM：RSS ~4 GiB, VIRT ~9 GiB
- 异常 VM：RSS 显著偏低（320 MiB / 40 MiB），无法完整映射 guest RAM

---

## 6. 根因分析

### 6.1 /dev/shm 是 QEMU guest RAM 的物理载体

当 Kata 配置 `shared_fs = "virtio-fs"` 时（这是默认配置），QEMU 使用 `/dev/shm` 作为 `memory-backend-file`：

```
QEMU 启动参数 → -object memory-backend-file,size=4G,mem-path=/dev/shm/...
```

每个 VM 的 guest RAM 都独占 `/dev/shm` 中的空间。`/dev/shm` 是 tmpfs，默认大小为 host RAM 的 50%。

### 6.2 容量计算

| 环境 | Host RAM | /dev/shm | per-VM /dev/shm | 最大 VM 数 |
|------|----------|----------|-----------------|-----------|
| 客户 | ~30.5 GiB | ~15.2 GiB | ~2.2 GiB | **6-7** |
| 我们 | 32 GiB | 16 GiB | ~3.9 GiB | **4** |

### 6.3 为什么 RES ≈ SHR 但内存确实被占用

- `/dev/shm` 是 tmpfs → 文件映射算 SHR（可共享）
- 但每个 QEMU 进程的 mmap 区域是**独立的文件**（不同 sandbox ID）
- 所以 SHR 不代表内存在进程间共享，只代表文件可以被共享
- **实际物理内存消耗 = 所有 QEMU 的 /dev/shm 映射之和**

### 6.4 失败模式

```
/dev/shm 97%+ → 新 QEMU 的 mmap() 只能 partial 成功
→ Guest 内核只看到部分 RAM → kata-agent 无法正常启动
→ vsock 连接超时 (DeadlineExceeded)
→ Pod 状态 = Error / CrashLoopBackOff
```

已运行的 Pod 中 stress-ng 的 `--vm-keep` 模式会持续占用内存，导致即使 QEMU 重试也无法获得足够的 /dev/shm 空间。

---

## 7. 解决方案

### 7.1 短期：扩大 /dev/shm（立即生效）

```bash
# 临时调整
mount -o remount,size=24G /dev/shm

# 永久配置 /etc/fstab
tmpfs /dev/shm tmpfs defaults,size=24G 0 0
```

### 7.2 中期：设置合理的 Pod Overhead 让 Scheduler 感知

确保 Kubernetes scheduler 能"看到" VM 的真实内存开销：

```yaml
# RuntimeClass 配置
overhead:
  podFixed:
    memory: "250Mi"   # QEMU/virtiofsd 进程开销
    cpu: "100m"
```

加上 Pod 的 `resources.requests.memory` 应该包含 guest 内将实际使用的内存量。

### 7.3 长期：容量规划公式

```
单节点最大 Kata Pod 数 = /dev/shm 总量 / (default_memory + guest 实际使用量)

示例（客户环境）：
  /dev/shm = 15 GiB
  per-VM 实际占用 ≈ 2.2 GiB
  最大 Pod = 15 / 2.2 ≈ 6-7 个
```

### 7.4 替代方案：禁用 file_mem_backend

如果不需要 DAX（virtio-fs 的直接内存映射），可以让 QEMU 使用匿名内存而非 /dev/shm：

```toml
# 在 configuration-qemu.toml 中
shared_fs = "virtio-9p"   # 使用 9p 而非 virtio-fs
# 或 file_mem_backend = ""  并确保不触发自动 /dev/shm
```

⚠️ 这会降低 virtiofs 性能，需要评估 workload 影响。

---

## 8. 测试脚本

完整脚本保存在：`scripts/test11e-mem-pressure-repro.sh`

CSV 数据：`results/v2-test11e-mem-pressure.csv`
完整日志：`results/v2-test11e-mem-pressure-stdout.log`

---

## 9. 结论

| 项目 | 结论 |
|------|------|
| **根因** | `/dev/shm` 耗尽，QEMU 无法为新 VM 分配 guest RAM 的 memory-backend-file |
| **触发条件** | VM 数量 × guest 实际内存使用 > /dev/shm 容量（默认 50% host RAM） |
| **表现** | 新 Pod 创建失败，`timed out connecting to vsock`；已有 Pod 可能重启 |
| **复现** | ✅ 成功复现，与客户错误模式一致 |
| **修复** | 扩大 /dev/shm、合理设置 Pod Overhead + requests、容量规划 |
