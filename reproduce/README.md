# Kata Agent Timeout 复现报告

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

## Step-by-Step 复现步骤

### Step 1: 确认节点配置

```bash
# 确认 Kata 配置
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  grep -E "^default_vcpus|^default_memory|^default_maxvcpus" \
  /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml

# 输出：
# default_vcpus = 5
# default_memory = 2048
# default_maxvcpus = 0
```

```bash
# 确认节点资源
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- nproc    # 8
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h  # 30Gi total
```

### Step 2: 部署 8 个 Kata Pod（匹配客户配置）

**脚本**: `test11f-customer-repro.sh`（见 reproduce 目录）

每个 Pod 匹配客户的 4 容器配置：

```yaml
spec:
  runtimeClassName: kata-qemu
  overhead:
    memory: "640Mi"
    cpu: "500m"
  containers:
  - name: gateway       # nginx, 150m/1Gi request, 1500m/2Gi limit, 含 liveness/readiness probe
  - name: config-watcher # busybox loop, 100m/256Mi request
  - name: envoy          # busybox dd loop, 100m/256Mi request
  - name: wazuh          # busybox find loop, 100m/512Mi request
```

**Pod 资源计算：**
```
Container requests: 450m CPU / 2Gi memory
Kata overhead:      500m CPU / 640Mi memory
Pod scheduling:     950m CPU / ~2.6Gi memory
8 pods total:       7600m / 8000m = 95% CPU requests
```

```bash
# 执行部署脚本
bash /home/ec2-user/kata-benchmark-v2/scripts/test11f-customer-repro.sh
```

### Step 3: 确认全部 Pod 启动成功

```bash
kubectl get pods -A -l app=customer-repro
```

结果：8 个 pod 全部 4/4 Running，0 restarts。

部署阶段 host 状态：
```
Host CPU: ~22% (8 QEMU 进程各 ~20% CPU)
MemAvailable: 27,095 MiB
/dev/shm: 2,557 MiB used
QEMU RSS: 平均 ~420 MiB per VM
```

**此时尚无崩溃**——轻负载下 CPU 争抢不严重。

### Step 4: 注入 CPU 压力（模拟客户业务负载）

客户的 pod 有实际业务负载（gateway 流量处理等），我们通过 stress-ng 模拟：

```bash
# 在每个 pod 的 gateway 容器中安装 stress-ng
for i in $(seq 1 8); do
  kubectl exec -n t11f-$i sandbox-$i -c gateway -- sh -c \
    "apt-get update -qq >/dev/null 2>&1 && \
     apt-get install -y -qq stress-ng >/dev/null 2>&1"
done

# 启动 CPU 压力（每个 VM 内 4 个 CPU worker）
for i in $(seq 1 8); do
  kubectl exec -n t11f-$i sandbox-$i -c gateway -- sh -c \
    "stress-ng --cpu 4 --timeout 0 &"
done
```

### Step 5: 观察崩溃

注入 stress-ng 后，在 **02:18:10 UTC** 所有 8 个 VM **同时崩溃**：

```bash
kubectl get pods -A -l app=customer-repro
```

```
NAMESPACE   NAME        READY   STATUS    RESTARTS
t11f-1      sandbox-1   4/4     Running   4 (14m ago)
t11f-2      sandbox-2   4/4     Running   4 (15m ago)
t11f-3      sandbox-3   4/4     Running   4 (15m ago)
t11f-4      sandbox-4   4/4     Running   4 (14m ago)
t11f-5      sandbox-5   4/4     Running   4 (14m ago)
t11f-6      sandbox-6   4/4     Running   4 (14m ago)
t11f-7      sandbox-7   4/4     Running   4 (14m ago)
t11f-8      sandbox-8   4/4     Running   4 (14m ago)
```

**所有 pod 都经历了 4 次 restart。**

## containerd 崩溃日志（与客户完全一致）

以下是从 `journalctl -u containerd` 提取的崩溃链路：

```
02:18:10.655 [WARN]  failed to ping hypervisor process: guest failure: internal-error
                     sandbox=2088eb78...

02:18:10.655 [WARN]  failed to ping agent: Failed to Check if grpc server is working: Dead agent
                     sandbox=2088eb78...

02:18:10.655 [WARN]  sandbox stopped unexpectedly
                     error="failed to ping hypervisor process: guest failure: internal-error"

02:18:10.655 [ERROR] Wait for process failed  container=1692d97e... error="Dead agent"
02:18:10.655 [ERROR] Wait for process failed  container=dba7870b... error="Dead agent"
02:18:10.655 [ERROR] Wait for process failed  container=70fe2ebc... error="Dead agent"
02:18:10.656 [ERROR] Wait for process failed  container=0fa2949f... error="Dead agent"
             → 4 个容器同时报 Dead agent（与客户一致）

02:18:10.660 [WARN]  Agent did not stop sandbox  error="Dead agent"

02:18:10.817 [INFO]  received container exit event  exit_status:255
02:18:11.005 [INFO]  received container exit event  exit_status:255
02:18:11.005 [INFO]  received container exit event  exit_status:255
02:18:11.005 [INFO]  received container exit event  exit_status:255
             → 所有容器 exit 255（与客户一致）

02:18:11.160 [INFO]  received sandbox exit event  exit_status:255

02:18:11.182 [ERROR] failed to delete dead shim
                     error="open /run/vc/sbs/<sandbox-id>: no such file or directory"
             → shim 清理失败（与客户一致）
```

**崩溃链路完全匹配客户报告中的序列。**

## Host top（崩溃恢复后）

```
top - 02:33:10 up 1 day, 14 min
Tasks: 255 total,   1 running, 254 sleeping
%Cpu(s): 23.2 us, 15.2 sy,  0.0 ni, 61.6 id
MiB Mem : 31554.9 total, 16093.1 free, 1502.0 used, 13959.8 buff/cache

  PID     %CPU  %MEM  RSS(MiB)  COMMAND
 511078   150   1.2   620       qemu-system-x86   ← 刚重启的 VM（高 CPU 是 warm up）
 510494   21.9  1.2   640       qemu-system-x86
 509965   21.8  1.2   627       qemu-system-x86
 510774   21.5  1.2   616       qemu-system-x86
 509679   21.4  1.2   625       qemu-system-x86
 509657   21.4  1.2   612       qemu-system-x86
 510465   20.5  1.2   623       qemu-system-x86
 511430   20.4  1.2   617       qemu-system-x86
```

## 数据汇总

### 部署阶段（无负载）

| Phase | Pods | Running | Host CPU | MemAvail | /dev/shm | QEMU RSS | QEMU CPU |
|-------|------|---------|----------|----------|----------|----------|----------|
| baseline | 0 | 0 | 0% | 30,020 MiB | 0 | 0 | 0% |
| deploy-1 | 1 | 1 | 13% | 29,638 MiB | 274 MiB | 399 MiB | 18% |
| deploy-2 | 2 | 2 | 14% | 29,350 MiB | 553 MiB | 808 MiB | 37% |
| deploy-3 | 3 | 3 | 17% | 29,049 MiB | 837 MiB | 1,216 MiB | 56% |
| deploy-4 | 4 | 4 | 19% | 28,720 MiB | 1,124 MiB | 1,627 MiB | 78% |
| deploy-5 | 5 | 5 | 20% | 28,391 MiB | 1,422 MiB | 2,052 MiB | 99% |
| deploy-6 | 6 | 6 | 21% | 28,027 MiB | 1,737 MiB | 2,483 MiB | 123% |
| deploy-7 | 7 | 7 | 21% | 27,672 MiB | 2,035 MiB | 2,879 MiB | 141% |
| deploy-8 | 8 | 8 | 22% | 27,259 MiB | 2,557 MiB | 3,365 MiB | 157% |

### Steady State 监控（无负载）

10 分钟内 0 restarts, 0 agent errors。**轻负载下不会触发。**

### 注入 stress-ng 后

| 事件 | 时间 |
|------|------|
| stress-ng 注入 | ~02:17 UTC |
| **全部 8 VM 同时崩溃** | **02:18:10 UTC** |
| containerd 报告 Dead agent | 02:18:10.655 |
| 所有容器 exit 255 | 02:18:10-11 |
| kubelet 重建所有 sandbox | 02:18:12+ |
| 恢复 Running | ~02:19 |

## Root Cause 分析

### 崩溃机制

```
stress-ng --cpu 4 × 8 VMs = 32 guest CPU workers
  + QEMU vCPU threads: smp=5 × 8 = 40 vCPU threads
  → 全部争抢 8 物理核（嵌套虚拟化下还有双层 VMExit 开销）

kata-monitor 每 10s ping kata-agent（VM 内）
  → agent 在 guest 内也需要 CPU 来响应
  → CPU 全部被 stress-ng 占满 → agent 无法响应
  → monitor 判定 "guest failure: internal-error"
  → 触发 sandbox stop → 所有容器 exit 255
```

### 为什么所有 VM 同时崩溃

嵌套虚拟化下，host 物理 CPU 是共享的。当所有 VM 同时打满 guest CPU：
1. QEMU 的 vCPU 线程全部可运行（runnable），争抢物理核
2. kata-agent 的 heartbeat 线程优先级不高于 workload
3. **一个 VM 的 agent 超时 → 该 VM 被杀 → 释放 CPU → 其他 VM 短暂获得更多 CPU**
4. 但由于所有 VM 同时处于压力下，多个 agent 几乎同时超时
5. 结果：**级联崩溃**，所有 VM 在同一秒内被判定 Dead

### 与客户环境的对应关系

| 特征 | 客户 | 复现 |
|------|------|------|
| 错误信息 | `failed to ping agent: Dead agent` | ✅ 完全一致 |
| exit code | 255 | ✅ 完全一致 |
| 4 容器同时退出 | ✅ | ✅ |
| `sandbox stopped unexpectedly` | ✅ | ✅ |
| `failed to delete dead shim` + `/run/vc/sbs/<id>: no such file` | ✅ | ✅ |
| 重启次数 | 最多 31 次 | 4 次（观测时间短） |
| 触发条件 | 业务负载 CPU 争抢 | stress-ng 模拟 |

## 修复建议

### 短期（立即可做）

1. **减少 default_vcpus**：`default_vcpus = 2`（从 5 降低）
   - 减少 guest vCPU 线程数，降低 host CPU 争抢
   - 客户 container CPU requests 只有 450m，不需要 5 vCPU

2. **减少每节点 pod 数**：最多 5-6 个（从 7 个降低）
   - 目标 CPU requests < 70%

3. **调大 agent ping 超时**：
   ```toml
   # configuration-qemu.toml
   [agent.kata]
   # 默认 kata-monitor 超时约 10s，建议增大
   dial_timeout = 30
   ```

### 中期

4. **增大 Kata overhead CPU**：从 500m 增大到 1000m
   - 让 scheduler 为 QEMU 进程预留更多 CPU

5. **使用 CPU pinning / cgroup 限制**：
   - 给每个 VM 的 QEMU 进程设置 CPU affinity
   - 避免所有 VM 争抢同一组物理核

### 长期

6. **使用裸金属实例**（如 m8i.metal）
   - 消除嵌套虚拟化开销（双层 VMExit → 单层）
   - CPU 效率提升 ~40-60%

7. **评估 Firecracker/Cloud Hypervisor**
   - 更轻量的 VMM，overhead 更小

## 文件清单

```
reproduce/
├── README.md                              ← 本文件
├── test11f-customer-repro.sh              ← 复现脚本
├── v2-test11f-customer-repro-stdout.log   ← 脚本完整输出
├── v2-test11f-customer-repro.csv          ← 数据 CSV
├── containerd-crash-logs.txt              ← containerd 崩溃日志
├── host-top.txt                           ← host top + ps + free + /dev/shm
├── pod-status.txt                         ← Pod 状态 + describe
├── kata-config.txt                        ← Kata QEMU 完整配置
└── dmesg.txt                              ← host dmesg
```
