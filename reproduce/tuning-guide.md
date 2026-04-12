# Kata Containers 生产调优指南

## 概述

基于 Test 1-11 的完整 benchmark 数据，本文档提供 Kata Containers on EKS 的生产环境调优建议。

---

## 1. vCPU 配置调优

### 问题

`default_vcpus` 决定每个 Kata guest VM 的 CPU 核数（QEMU `-smp N`）。默认值或过大的值导致：
- Host 上 vCPU 线程过多 → CPU 争抢
- 嵌套虚拟化下 VMExit 频率成倍增长
- kata-agent heartbeat 超时 → Dead Agent 级联崩溃

### 调优建议

```toml
# /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
default_vcpus = 2
```

**选择依据**：

| default_vcpus | 适用场景 | 7 VMs / 8 cores 超配比 |
|---------------|---------|----------------------|
| 1 | 极轻负载（纯 sidecar） | 0.9:1 ✅ 但单容器 burst 受限 |
| **2** | **大多数 Web 应用** | **1.75:1** ✅ 推荐 |
| 4 | 计算密集型（ML inference） | 3.5:1 ⚠️ 需要大机型 |
| 5+ | 仅限裸金属或低密度部署 | 4.4:1 ❌ 嵌套虚拟化下不可接受 |

**公式**：
```
超配比 = (pods_per_node × default_vcpus) / host_physical_cores
目标: 超配比 < 2:1（嵌套虚拟化），< 3:1（裸金属）
```

---

## 2. Pod Overhead 配置

### 问题

Kata pod 的实际内存占用远大于容器 cgroup 报告值。如果不配置 Pod Overhead，调度器会过度装箱。

### 调优建议

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    cpu: "100m"      # QEMU idle CPU（实测 ~50m，留 buffer）
    memory: "250Mi"  # 实测 207 MiB + 20% buffer (Test 7/8 基准)
```

**内存 overhead 选择**：

| 场景 | 推荐 memory overhead | 说明 |
|------|---------------------|------|
| 通用工作负载 | **250Mi** | 覆盖 QEMU + guest kernel + virtiofsd |
| 高密度部署（>5 pods/node） | **400-640Mi** | 额外安全余量，防止突发 |
| 大内存 pod（limits > 8Gi） | **500Mi+** | Guest kernel 页表开销随内存增长 |

**CPU overhead 说明**：
- Overhead CPU 只影响调度器账本，**不限制 QEMU 实际 CPU 使用**
- 不能替代调整 `default_vcpus` 来解决 CPU 争抢
- 100m 足够覆盖 QEMU idle 开销

---

## 3. Liveness/Readiness Probe 调优

### 问题

Kata guest 内的响应延迟高于 runc（需穿越 VM 边界 + 嵌套虚拟化 VMExit）。默认 1s timeout 在内存/CPU 压力下容易触发误杀。

### 调优建议

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 15    # Kata VM 启动比 runc 慢 3-5s
  periodSeconds: 10
  timeoutSeconds: 5          # 从默认 1s 增大到 5s
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3          # readiness 可以稍短
  failureThreshold: 3
```

**关键参数**：
| 参数 | runc 推荐 | Kata 推荐 | 原因 |
|------|----------|----------|------|
| initialDelaySeconds | 5-10 | **15-30** | VM boot + guest kernel 初始化 |
| timeoutSeconds | 1 | **3-5** | 穿越 VM 边界 + 嵌套虚拟化延迟 |
| failureThreshold | 3 | **3-5** | 容忍短暂的 guest 内存/CPU 波动 |

---

## 4. 内存监控策略

### 问题

`kubectl top pod` 严重低估 Kata pod 的实际内存占用（Test 11g 实测：7.8 GiB vs 真实 17.0 GiB）。

### 四层内存可见性

```
Layer 1: kubectl top pod      → guest 内容器 cgroup（最不准确）
Layer 2: QEMU RSS (/proc/PID) → 进程级物理内存（较准确）
Layer 3: kubectl top node      → host cgroup 总量（推荐告警基准）
Layer 4: host free -m          → 物理内存全貌（最准确）
```

### 调优建议

1. **告警基于 node 级指标**，不要用 pod 级
2. 使用 Prometheus node_exporter 监控：
   - `node_memory_MemAvailable_bytes` — 可用内存
   - `node_memory_Shmem_bytes` — QEMU memfd 共享映射
3. 告警阈值：`MemAvailable < 20%` 时预警，`< 10%` 时告警
4. 容量规划公式：
   ```
   每 pod 实际内存 ≈ sum(container_limits) + overhead(250Mi) + guest_kernel(~400Mi)
   节点最大 pod 数 = (Node_Allocatable × 0.8) / 每 pod 实际内存
   ```

---

## 5. 节点容量规划

### 每节点 Pod 数量建议

| 机型 | vCPU | Memory | 推荐 max pods (vcpus=2) | 推荐 max pods (vcpus=4) |
|------|------|--------|------------------------|------------------------|
| m8i.xlarge | 4 | 16 GiB | 2-3 | 1-2 |
| m8i.2xlarge | 8 | 32 GiB | 4-6 | 3-4 |
| m8i.4xlarge | 16 | 64 GiB | 8-12 | 6-8 |
| m8i.metal | 128 | 512 GiB | 60-80 | 40-60 |

**计算方法**：
```
CPU 维度: max_pods = host_cores / default_vcpus × 0.7  (留 30% headroom)
Memory 维度: max_pods = (host_memory × 0.8) / (sum_limits + 650Mi)
取两者较小值
```

### 裸金属 vs 嵌套虚拟化

| 维度 | 嵌套虚拟化 (EC2) | 裸金属 (metal) |
|------|-----------------|---------------|
| VMExit 开销 | 双层（L2→L1→L0） | 单层（L1→L0） |
| CPU 效率 | ~60-70% | ~90-95% |
| 安全超配比 | < 2:1 | < 3:1 |
| Dead Agent 风险 | 高（CPU 争抢放大） | 低 |
| 推荐场景 | 开发/测试 | **生产** |

---

## 6. Kata Agent 超时配置

### 问题

kata-monitor 默认 heartbeat 超时较短，CPU 争抢时容易误判 Dead Agent。

### 调优建议

```toml
# /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
[agent.kata]
dial_timeout = 30        # 默认可能是 10s，增大到 30s
```

**权衡**：超时越大，真正的 VM 故障被发现越晚，但误判率越低。

---

## 7. Sidecar 启动顺序优化

### 问题

多个 sidecar 同时分配大量内存时，guest 内存风暴导致主容器 probe 超时。

### 调优建议

1. **使用 init containers 预分配内存**：
   ```yaml
   initContainers:
   - name: pre-warm
     image: busybox:1.36
     command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/warm bs=1M count=100 && rm /dev/shm/warm"]
   ```

2. **错开 sidecar 启动**：在 sidecar command 中加 `sleep` 延迟
   ```yaml
   args: ["sleep 10 && <actual_command>"]
   ```

3. **给主容器更长的 initialDelaySeconds**（见 Section 3）

---

## 8. 配置速查表

```yaml
# RuntimeClass
overhead:
  podFixed:
    cpu: "100m"
    memory: "250Mi"

# Kata TOML
default_vcpus = 2
default_memory = 2048
# dial_timeout = 30

# Pod Spec probes
livenessProbe:
  timeoutSeconds: 5
  initialDelaySeconds: 15
readinessProbe:
  timeoutSeconds: 3
  initialDelaySeconds: 10
```

**节点容量公式**：
```
max_pods = min(
  host_cores / default_vcpus × 0.7,
  host_memory_GiB × 0.8 / per_pod_actual_GiB
)
```

---

## 参考数据

| 指标 | 值 | 来源 |
|------|-----|------|
| QEMU 空载内存 overhead | 207 MiB | Test 7 |
| virtiofsd 内存 | ~40 MiB | Test 7 |
| Guest kernel 内存 | ~200-400 MiB | Test 11g |
| kubectl top pod 低估比例 | ~2.2x | Test 11g (7.8G vs 17.0G) |
| CPU 争抢 → Dead Agent 阈值 | 超配比 > 3:1 | Test 11f |
| 嵌套虚拟化 CPU 效率 | ~60-70% | Test 6 |
| 网络吞吐损失 (kata-qemu vs runc) | -50% | Test 3 |
| 网络延迟增加 | +13x | Test 4 |
