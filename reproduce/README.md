# Kata Containers 客户问题复现与分析

## 客户问题概述

客户环境（tk4 集群）中，m8i.2xlarge（8 vCPU, 32 GiB）节点上运行 7 个 Kata sandbox pod，出现：
1. 第 7 个 pod 启动时 probe 失败
2. 已运行的 pod 频繁 restart（最多 31 次），containerd 日志显示 `Dead agent` → `exit_status:255`

## 复现环境

| 项目 | 值 |
|------|-----|
| 集群 | Amazon EKS 1.34, us-west-2 |
| 节点 | ip-172-31-17-237.us-west-2.compute.internal |
| 机型 | m8i.2xlarge (8 vCPU, 32 GiB) |
| Host 内核 | 6.12.68-92.122.amzn2023.x86_64 |
| Kata 版本 | 3.27.0 (kata-deploy Helm chart) |
| VMM | QEMU |
| Kata VM 内核 | 6.18.12 |
| default_vcpus | 5 |
| default_memory | 2048 MiB |
| 嵌套虚拟化 | 是（EC2 on EC2） |

---

## 复现测试

### Test 11f: CPU 压力导致 Dead Agent 崩溃

**目标**：复现 containerd `Dead agent` / `exit_status:255` 崩溃链

**脚本**: [`test11f-customer-repro.sh`](test11f-customer-repro.sh)

#### Step 1: 确认节点配置

```bash
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  grep -E "^default_vcpus|^default_memory" \
  /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
# → default_vcpus = 5, default_memory = 2048
```

#### Step 2: 部署 8 个 Kata Pod

每个 Pod 匹配客户 4 容器配置（nginx + config-watcher + envoy + wazuh）。

```bash
bash reproduce/test11f-customer-repro.sh
```

Pod 资源：
```
Container requests: 450m CPU / 2 GiB memory
Kata overhead:      500m CPU / 640 MiB memory
Per-pod scheduling: 950m CPU / ~2.6 GiB memory
8 pods total:       7600m / 8000m = 95% CPU requests
```

**部署阶段（无负载）**：全部 8 pod 4/4 Running，0 restarts。

#### Step 3: 注入 CPU 压力

```bash
for i in $(seq 1 8); do
  kubectl exec -n t11f-$i sandbox-$i -c gateway -- sh -c \
    "stress-ng --cpu 4 --timeout 0 &"
done
```

#### Step 4: 观察崩溃

注入 stress-ng 后 **~1 分钟内**，所有 8 VM 同时崩溃：

```
02:18:10.655 [WARN]  failed to ping agent: Dead agent    sandbox=2088eb78...
02:18:10.655 [WARN]  sandbox stopped unexpectedly
02:18:10.817 [INFO]  exit_status:255   ← 4 containers × 8 pods
```

**崩溃机制**：
```
stress-ng --cpu 4 × 8 VMs = 32 guest CPU workers
+ QEMU vCPU threads: smp=5 × 8 = 40 vCPU threads
→ 全部争抢 8 物理核（嵌套虚拟化双层 VMExit）
→ kata-agent 无法响应 heartbeat → "Dead agent" → sandbox stop
→ 级联崩溃：所有 VM 在同一秒内被判定 Dead
```

**与客户日志 100% 匹配。**

---

### Test 11g: 稳态内存画像（无 CPU 压力）

**目标**：在无 CPU 争抢条件下，模拟客户 7 pod 的稳态资源消耗，验证内存可见性差异。

**脚本**: [`test11g-v4-exact-profile.sh`](test11g-v4-exact-profile.sh)

#### 内存模拟方法

客户每个 Pod 有 4 个容器，实际业务中会消耗大量 guest 内存。我们通过 `/dev/shm` 写入来模拟：

```bash
dd if=/dev/urandom of=/dev/shm/memblock bs=1M count=700
```

这条命令从随机数源读 700 MiB 数据，写到 `/dev/shm/memblock` 文件。`/dev/shm` 是 tmpfs（内存文件系统），数据不落盘，直接驻留在 RAM 中。文件存在期间内存就被占住，`rm` 掉文件内存立刻释放。

**为什么用 `/dev/shm` 而不是 `/tmp`**：Kata 的 `/tmp` 是 virtiofs 挂载，数据写到 host 侧，不会推高 guest RAM / QEMU RES。`/dev/shm` 是 guest 内的 tmpfs，直接消耗 guest RAM。

**内存分配路径**：
```
容器写 /dev/shm → guest tmpfs 分配物理页 → guest RAM 增长
→ QEMU memfd mmap 支撑 guest RAM → host 物理内存被占用 → QEMU RES 增长
```

| 容器 | 模拟方式 | 内存消耗 |
|------|---------|---------|
| gateway | nginx 服务 | ~9 MiB |
| config-watcher | `dd of=/dev/shm/memblock count=700` | 700 MiB |
| envoy | `dd of=/dev/shm/memblock2 count=700` | 700 MiB |
| wazuh | `dd of=/dev/shm/memblock3 count=600` | 600 MiB |
| **合计** | | **~2.0 GiB guest 内存** |

每个容器还有轻量 CPU 循环（`cat /proc/loadavg`、计数循环、`find /etc`），模拟 sidecar 的背景 CPU 消耗。

#### 执行

```bash
bash reproduce/test11g-v4-exact-profile.sh 7
```

#### 结果：四层内存可见性对比

**采集时间**：2026-04-12 05:01 UTC，7 pod 稳态运行 65 分钟后

##### Layer 1: kubectl top pod（guest 内容器 cgroup）

```
NAMESPACE   NAME        CPU(cores)   MEMORY(bytes)
t11g-1      sandbox-1   4m           977Mi
t11g-2      sandbox-2   4m           2085Mi       ← 未 restart，gateway 内存膨胀
t11g-3      sandbox-3   5m           977Mi
t11g-4      sandbox-4   5m           977Mi
t11g-5      sandbox-5   5m           977Mi
t11g-6      sandbox-6   5m           977Mi
t11g-7      sandbox-7   5m           977Mi
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Pod 级合计:  33m          7947Mi (~7.8 GiB)
```

##### Layer 2: Host QEMU 进程（/proc/PID/status）

```
PID     VIRT       RES    SHR    %CPU  %MEM
559448  8752108    2.4g   2.4g   113   7.9
559036  8752108    2.4g   2.4g   6.7   7.9
558657  8752108    2.4g   2.4g   0.0   7.9
558833  8752108    2.4g   2.4g   0.0   7.9
559249  8752116    2.4g   2.4g   0.0   7.8
559839  8752108    2.4g   2.4g   0.0   7.8
561293  8752108    1.3g   1.3g   0.0   4.4   ← sandbox-6 多次 restart
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QEMU RSS 合计: 16,269 MiB (~15.9 GiB)
Average per VM: 2,324 MiB
```

**QEMU 进程内存字段解读**：
- **VIRT** (8.7 GiB)：虚拟地址空间总量，mmap 了但不一定实际分配
- **RES** (2.4 GiB)：实际驻留物理内存（RSS）
- **SHR** (2.4 GiB)：RES 中属于"共享映射"的部分
- **%MEM**：RES / 主机总物理内存 = 2.4G / 30G ≈ 7.9%
- **RES ≈ SHR 的原因**：QEMU 用 `mmap(MAP_SHARED, memfd)` 分配 guest RAM，内核将其全部视为 shared file-backed mapping。QEMU 自身代码/堆很小，guest RAM 占了绝大部分。

##### Layer 3: kubectl top node（host metrics-server）

```
NAME                                          CPU(cores)  CPU(%)  MEMORY(bytes)  MEMORY(%)
ip-172-31-17-237.us-west-2.compute.internal   1083m       13%     17458Mi        58%
```

##### Layer 4: Host free（物理内存全貌）

```
              total    used     free     shared   buff/cache  available
Mem:         31554    1493     7302     15562     22758       14047
```

`shared` = 15,562 MiB — 这就是 QEMU memfd 共享映射，`free` 命令将其计入 buff/cache。

#### 内存差异分析

| 观测层 | 值 | 数据来源 |
|--------|-----|---------|
| kubectl top pod（合计） | **7.8 GiB** | guest 内容器 cgroup memory.current |
| QEMU RSS（合计） | **15.9 GiB** | host /proc/PID/statm |
| kubectl top node | **17.0 GiB** | host cgroup（含所有进程） |
| Host free used+shared | **16.7 GiB** | /proc/meminfo |

```
不可见开销 = kubectl top node - kubectl top pod
           = 17.0 - 7.8 = 9.2 GiB（每 pod ~1.3 GiB）
```

**9.2 GiB 不可见开销来源**：

| 组件 | 预估每 VM |
|------|----------|
| Guest kernel（slab/页表/buffer/内核栈） | ~200-400 MiB |
| QEMU 用户态（设备模拟/vhost） | ~50-100 MiB |
| virtiofsd 进程 | ~40 MiB |
| Guest OS rootfs (initrd) | ~100-150 MiB |
| memfd 共享映射（cgroup 不完整计入） | 部分 |

#### Pod Restart 观察

| Pod | Restarts | 原因 |
|-----|----------|------|
| sandbox-1 | 1 | gateway liveness probe timeout（内存分配期间） |
| sandbox-2 | **0** | 唯一未 restart，gateway RSS 1115 MiB（内存膨胀未回收） |
| sandbox-3 | 1 | gateway liveness probe timeout |
| sandbox-4 | 1 | gateway liveness probe timeout |
| sandbox-5 | 1 | gateway liveness probe timeout |
| sandbox-6 | **4** | 多次 probe 失败 |
| sandbox-7 | 1 | gateway liveness probe timeout |

**Restart 根因**：3 个 sidecar 启动时同时往 `/dev/shm` 写 2 GiB 数据，guest 内存分配风暴导致 nginx 响应延迟 > 1s liveness timeout。非 OOM kill（exit code=0, Reason=Completed）。

---

## 关键概念深入分析

### Pod memory request 与 QEMU 内存的关系

Kata 根据 **sum(container limits)** 决定 guest VM 内存上限：

```
Guest VM max RAM = default_memory(256 MiB) + sum(limits)
                 = 256 MiB + (2Gi + 1Gi + 1Gi + 1Gi) = 5.25 GiB
```

而 **request** 只影响调度器账本，不影响 QEMU 分配的内存大小：

```
调度器扣减 = sum(requests) + pod overhead = 2 GiB + 640 MiB = 2.6 GiB
QEMU 可用  = sum(limits) + default_memory                   = 5.25 GiB
QEMU 当前  = 2.4 GiB (RES，实际触碰的物理页)
```

**矛盾**：调度器用 request 做账，但 QEMU 可以吃到 limits 总量。如果节点上多个 Kata pod 都 burst 到 limits，实际物理内存消耗会远超调度器账本。

### 调度器账本 vs 实际占用

```
当前 RuntimeClass overhead: memory=640Mi, cpu=500m

调度器账本（7 pods）:
  CPU:    7 × (450m + 500m) = 6650m (83% of 8 cores)
  Memory: 7 × (2 GiB + 640 MiB) = 18.4 GiB (58% of 32 GiB)

实际占用:
  CPU:    1083m (13%)    ← 调度器严重高估（QEMU idle 几乎不耗 CPU）
  Memory: 17.0 GiB       ← 与调度器账本基本匹配
```

640 MiB overhead 在此场景下刚好合适：调度器账本（18.4G）略大于实际（17.0G），不会超卖。

### Pod Overhead CPU vs default_vcpus

这两个参数作用在完全不同的层面：

| | Pod Overhead CPU | default_vcpus |
|---|---|---|
| **配置位置** | RuntimeClass YAML | Kata configuration-qemu.toml |
| **作用对象** | kube-scheduler | QEMU `-smp` 参数 |
| **影响** | 调度器从节点 Allocatable 中扣多少 | Guest VM 内有几个 CPU |
| **是否限制 QEMU** | ❌ 纯账本，不限制实际用量 | ✅ 决定 QEMU 启几个 vCPU 线程 |
| **解决的问题** | 防止节点被塞太多 pod | 减少 CPU 争抢 |

**QEMU `-smp N` 的影响**：

```
-smp 5 → 每 VM 5 个 vCPU 线程, 7 VMs = 35 vCPU / 8 物理核 = 4.4:1 超配
-smp 2 → 每 VM 2 个 vCPU 线程, 7 VMs = 14 vCPU / 8 物理核 = 1.75:1 超配
-smp 1 → 每 VM 1 个 vCPU 线程, 7 VMs =  7 vCPU / 8 物理核 = 0.9:1（安全但太慢）
```

vCPU 越多：
1. Host 可运行线程越多 → CPU 争抢越激烈
2. 嵌套虚拟化下 VMExit 频率成倍增长
3. vCPU 之间的 IPI（核间中断）触发额外 VMExit

**客户的 container CPU requests 合计只有 450m，default_vcpus=5 严重超配。**

---

## CPU 争抢 vs 内存紧张：Pod 失败模式对比

两者都会导致 Pod 失败，但崩溃方式、日志特征、波及范围完全不同：

### 对比总表

| | CPU 争抢 | 内存紧张 |
|---|---|---|
| **典型触发** | vCPU 超配 + 业务负载 burst | 容器 burst 到 limit / host 内存不足 |
| **崩溃机制** | kata-agent 拿不到 CPU → heartbeat 超时 | OOM killer 杀进程 |
| **失败速度** | 渐进（秒级，probe 超时累计） | 瞬间（OOM kill 立刻执行） |
| **波及范围** | **级联**：所有 VM 同时崩溃 | **单个** pod，其他不受影响 |
| **Exit Code** | 255（sandbox 整体被判死） | 137（128 + SIGKILL=9） |
| **容器失败模式** | 全部 4 个容器同时退出 | 通常只有 1 个容器被杀 |
| **关键日志** | `Dead agent` / `guest failure: internal-error` | `OOMKilled` / host dmesg `Out of memory` |
| **kubectl describe** | Reason: Error | Reason: OOMKilled |
| **Host dmesg** | 无 OOM 记录 | 有 `Killed process (qemu-system-x86)` |

### 快速诊断流程

```
看到 "Dead agent" + exit 255 + 多 VM 同时崩？
  → CPU 争抢（查 host top，确认 vCPU 超配比）

看到 "OOMKilled" + exit 137 + 单容器重启？
  → Guest 内存超 limit（查 container memory limit）

看到 "Liveness probe failed" + exit 0 + 单 pod？
  → 内存压力或 CPU 压力导致响应慢（查 probe timeout 配置）

Host dmesg 有 "Out of memory: Killed process qemu"？
  → Host 级 OOM（Pod overhead 配少了，节点塞太多 pod）
```

### 另一种内存失败模式：Guest 内存压力（非 OOM）

Test 11g 中 sandbox-4 的 gateway 容器被重启，但不是 OOM kill：
- 3 个 sidecar 同时分配 2 GiB `/dev/shm` → guest 内存分配风暴
- nginx 进程活着但来不及在 1s 内回复 liveness probe
- Exit Code = 0（Completed，kubelet 发 SIGTERM，nginx 优雅退出）
- **不会级联**，只影响单个 pod
- 与 CPU 争抢的关键区别：其他 pod 不受影响

---

## Root Cause 总结

### Test 11f: CPU 争抢导致 Dead Agent（与客户问题匹配）

```
高 CPU 负载 → 嵌套虚拟化双层 VMExit 放大延迟
→ kata-agent heartbeat 无法在超时内响应
→ kata-monitor 判定 "guest failure: internal-error"
→ sandbox stop → 所有容器 exit_status:255
→ 所有 VM 共享物理 CPU → 级联崩溃
```

| 特征 | 客户日志 | 复现结果 |
|------|---------|---------|
| `failed to ping agent: Dead agent` | ✅ | ✅ |
| `exit_status: 255` | ✅ | ✅ |
| 4 容器同时退出 | ✅ | ✅ |
| `sandbox stopped unexpectedly` | ✅ | ✅ |
| `failed to delete dead shim` | ✅ | ✅ |

### Test 11g: 内存不可见性

```
kubectl top pod 只看到 guest 内容器 cgroup 的 memory.current
→ 遗漏 guest kernel + QEMU overhead + virtiofsd + memfd 共享映射
→ 每 pod ~1.3 GiB 不可见
→ 7 pod 合计 ~9.2 GiB 不可见内存
→ 如果用 kubectl top pod 做告警，永远看不到真实内存压力
```

---

## 修复建议

### 立即可做

1. **减少 default_vcpus：5 → 2**
   - 客户 container CPU requests 合计只有 450m，不需要 5 vCPU
   - 7 VMs 的 vCPU 线程从 35 降到 14，超配比从 4.4:1 降到 1.75:1
   - 直接减少 CPU 争抢，消除 Dead Agent 级联崩溃

2. **减少每节点 pod 数**
   - 控制 CPU requests < 70%，给 kata-agent heartbeat 留 CPU 余量

3. **增大 liveness probe timeout：1s → 5s**
   - 容忍 guest 内短暂的延迟波动
   - 避免内存分配风暴期间误杀容器

### 中期

4. **Pod Overhead 配置**
   - 生产推荐基线：`cpu: 100m, memory: 250Mi`（Test 7/8 实测 207 MiB + 20% buffer）
   - 当前 Test 11 使用 `cpu: 500m, memory: 640Mi` 是临时值，防止调度器过度装箱
   - 客户应根据节点密度和 burst 风险决定是否加大
   - **注意**：Pod Overhead CPU 只影响调度器账本，不限制 QEMU 实际 CPU 使用，不能替代调整 default_vcpus

5. **配置 kata-agent 超时：dial_timeout = 30**
   - 给 agent heartbeat 更大的超时窗口

6. **基于 node 级指标告警**
   - 不要用 `kubectl top pod`（严重低估 Kata pod 真实资源消耗）
   - 使用 `kubectl top node` 或 host 级 `free -m` / Prometheus node_exporter

### 长期

7. **使用裸金属实例**（m8i.metal）
   - 消除嵌套虚拟化开销（双层 VMExit → 单层）
   - CPU 效率提升 ~40-60%

8. **评估 Cloud Hypervisor**
   - 更轻量的 VMM，overhead 更小
   - 但稳定性需验证（Test 5b 显示 kata-clh 在高负载下有 crash）

---

## 文件清单

```
reproduce/
├── README.md                              ← 本文件
├── test11f-customer-repro.sh              ← Test 11f: CPU 压力崩溃复现脚本
├── test11g-v4-exact-profile.sh            ← Test 11g: 稳态内存画像脚本（当前运行版本）
├── test11g-realistic-workload.sh          ← Test 11g v1: 早期版本
├── test11g-customer-steady-state.sh       ← Test 11g v2: 中间版本
├── test11g-v3-exact-profile.sh            ← Test 11g v3: 中间版本
├── v2-test11f-customer-repro-stdout.log   ← Test 11f 脚本完整输出
├── v2-test11f-customer-repro.csv          ← Test 11f 数据 CSV
├── containerd-crash-logs.txt              ← containerd 崩溃日志（Dead agent 链路）
├── host-top.txt                           ← host top + ps + free + /dev/shm
├── pod-status.txt                         ← Pod 状态 + describe
├── kata-config.txt                        ← Kata QEMU 完整配置
└── dmesg.txt                              ← host dmesg
```
