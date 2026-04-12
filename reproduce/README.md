# Kata Containers 客户问题复现

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
# Kata 配置
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

#### 设计思路

客户每个 Pod 有 4 个容器，实际业务中会消耗大量 guest 内存。我们通过 `/dev/shm` 写入来模拟：

| 容器 | 模拟方式 | 内存消耗 |
|------|---------|---------|
| gateway | nginx 服务 | ~9 MiB |
| config-watcher | `dd if=/dev/urandom of=/dev/shm/memblock bs=1M count=700` | 700 MiB |
| envoy | `dd if=/dev/urandom of=/dev/shm/memblock2 bs=1M count=700` | 700 MiB |
| wazuh | `dd if=/dev/urandom of=/dev/shm/memblock3 bs=1M count=600` | 600 MiB |
| **合计** | | **~2.0 GiB guest 内存** |

**关键**：`/dev/shm` 在 Kata guest 内是 tmpfs，直接消耗 guest RAM → 推高 host 上 QEMU 进程的 RSS。

每个容器还有轻量 CPU 循环（`cat /proc/loadavg`、计数循环、`find /etc`），模拟 sidecar 的背景 CPU 消耗。

#### Pod Spec 核心配置

```yaml
spec:
  runtimeClassName: kata-qemu
  containers:
  - name: gateway
    image: nginx:1.27
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "1500m", memory: "2Gi" }
    livenessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 10
      periodSeconds: 10
  - name: config-watcher
    image: busybox:1.36
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  - name: envoy
    image: busybox:1.36
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  - name: wazuh
    image: busybox:1.36
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
```

#### 执行

```bash
bash reproduce/test11g-v4-exact-profile.sh 7
```

#### 结果：三层内存可见性对比

**采集时间**：2026-04-12 05:01 UTC，7 pod 稳态运行 65 分钟后

##### Layer 1: kubectl top pod（guest cgroup 层）

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

##### Layer 2: Host QEMU RES（进程 RSS 层）

```
PID     VIRT       RES    SHR    %CPU  %MEM
559448  8752108    2.4g   2.4g   113   7.9
559036  8752108    2.4g   2.4g   6.7   7.9
558657  8752108    2.4g   2.4g   0.0   7.9
558833  8752108    2.4g   2.4g   0.0   7.9
559249  8752116    2.4g   2.4g   0.0   7.8
559839  8752108    2.4g   2.4g   0.0   7.8
561293  8752108    1.3g   1.3g   0.0   4.4   ← sandbox-6 多次 restart 后 RSS 较低
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QEMU RSS 合计: 16,269 MiB (~15.9 GiB)
Average per VM: 2,324 MiB
```

##### Layer 3: kubectl top node（host cgroup 层）

```
NAME                                          CPU(cores)  CPU(%)  MEMORY(bytes)  MEMORY(%)
ip-172-31-17-237.us-west-2.compute.internal   1083m       13%     17458Mi        58%
```

##### Layer 4: Host free（物理内存）

```
              total    used     free     shared   buff/cache  available
Mem:         31554    1493     7302     15562     22758       14047
```

注意 `shared` = 15,562 MiB — 这就是 QEMU memfd 共享映射，`free` 命令将其计入 buff/cache。

#### 内存差异分析

```
           kubectl top pod    QEMU RSS    kubectl top node    Host free
合计:       7.8 GiB           15.9 GiB    17.0 GiB           used=1.5G + shared=15.2G

不可见开销 = kubectl top node - kubectl top pod
           = 17.0 - 7.8 = 9.2 GiB
           = 每 pod ~1.3 GiB
```

**9.2 GiB 不可见开销来源：**
| 组件 | 预估 |
|------|------|
| Guest kernel（slab/页表/buffer/内核栈） | ~200-400 MiB/VM |
| QEMU 用户态（设备模拟/vhost） | ~50-100 MiB/VM |
| virtiofsd 进程 | ~40 MiB/VM |
| memfd 共享映射不计入 cgroup | 部分重复统计 |
| Guest OS rootfs (initrd) | ~100-150 MiB/VM |

#### Pod Restart 观察

| Pod | Restarts | 原因 |
|-----|----------|------|
| sandbox-1 | 1 | gateway liveness probe timeout（内存分配期间） |
| sandbox-2 | **0** | 唯一未 restart，gateway RSS 1115 MiB（膨胀后未回收） |
| sandbox-3 | 1 | gateway liveness probe timeout |
| sandbox-4 | 1 | gateway liveness probe timeout |
| sandbox-5 | 1 | gateway liveness probe timeout |
| sandbox-6 | **4** | 多次 probe 失败，QEMU RSS 较低（1.3 GiB） |
| sandbox-7 | 1 | gateway liveness probe timeout |

**Restart 根因**：3 个 sidecar 启动时同时往 `/dev/shm` 写 2 GiB 数据，guest 内存分配风暴导致 nginx 响应延迟 > 1s liveness timeout。非 OOM kill（exit code=0, Reason=Completed）。

#### 调度器账本 vs 实际占用

```
RuntimeClass overhead: memory=640Mi, cpu=500m

调度器账本（每 pod）:
  requests  = 150m + 100m + 100m + 100m = 450m CPU
              1Gi + 256Mi + 256Mi + 512Mi = 2 GiB memory
  overhead  = 500m CPU, 640Mi memory
  total     = 950m CPU, 2.6 GiB memory

7 pods:     6650m CPU (83% of 8 cores)
            18.4 GiB memory (58% of 32 GiB)

实际 host:  1083m CPU (13%)
            17.0 GiB memory (kubectl top node)
```

调度器 CPU 严重高估（6.6 核 vs 实际 1 核），因为 QEMU idle 几乎不消耗 CPU。
调度器内存与实际基本匹配（18.4G 账本 vs 17.0G 实际），640Mi overhead 配置合理。

---

## Root Cause 总结

### Test 11f: CPU 争抢导致 Dead Agent

```
高 CPU 负载 → 嵌套虚拟化双层 VMExit 放大延迟
→ kata-agent heartbeat 无法在超时内响应
→ kata-monitor 判定 "guest failure: internal-error"
→ sandbox stop → 所有容器 exit_status:255
→ 所有 VM 共享物理 CPU → 级联崩溃
```

### Test 11g: 内存不可见性

```
kubectl top pod 只看到 guest 内容器 cgroup 的 memory.current
→ 遗漏 guest kernel + QEMU overhead + virtiofsd + memfd 共享映射
→ 每 pod ~1.3 GiB 不可见
→ 7 pod 合计 ~9.2 GiB 不可见内存
→ 必须用 kubectl top node 或 host free 做真实监控
```

---

## 修复建议

### 立即可做

1. **减少 default_vcpus**：5 → 2（客户 container CPU requests 只有 450m）
2. **减少每节点 pod 数**：控制 CPU requests < 70%
3. **增大 liveness probe timeout**：`timeoutSeconds: 5`（从默认 1s）

### 中期

4. **增大 Pod Overhead CPU**：500m → 1000m
5. **配置 QEMU agent 超时**：`dial_timeout = 30`
6. **基于 node 级指标告警**（不要用 kubectl top pod）

### 长期

7. **使用裸金属实例**（m8i.metal）消除嵌套虚拟化
8. **评估 Cloud Hypervisor**（更轻量但稳定性需验证）

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
