# gVisor 网络与存储性能评估

**测试日期：** 2026-04-14  
**节点：** ip-172-31-11-74 (m8i.2xlarge, 8 vCPU, 32 GiB)  
**gVisor：** runsc release-20260406.0  
**对比基线：** 同节点 runc 容器

---

## 1. gVisor 运行时验证

```
# dmesg 输出 — gVisor Sentry 特有标识
[   0.000000] Starting gVisor...
[   0.418025] Singleplexing /dev/ptmx...

# uname — gVisor 模拟内核 4.4.0（host 实际是 6.12.x）
Linux gvisor-verify 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016 x86_64

# /proc/version — 进一步确认
Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016
```

**三重验证**：dmesg 标识 + 模拟内核版本 4.4.0 + /proc/version 一致。确认 Pod 运行在 gVisor 用户态内核中。

---

## 2. 网络性能

### 2.1 TCP 吞吐 (iperf3, 4 parallel streams, 10s)

| 运行时 | 吞吐量 | 对比 runc |
|--------|--------|----------|
| **runc** | **86.0 Gbps** | 基线 |
| **gVisor** | **59.4 Gbps** | **-31%** |

### 2.2 延迟 (ping, 20 packets, pod-to-pod 同节点)

| 运行时 | 平均延迟 | 最小/最大 | 对比 runc |
|--------|---------|----------|----------|
| **runc** | **0.062 ms** | 0.049 / 0.084 ms | 基线 |
| **gVisor** | **0.394 ms** | 0.209 / 0.986 ms | **+535% (+6.4x)** |

### 2.3 与 Kata 运行时网络对比（历史数据）

| 运行时 | TCP 吞吐 | 对比 runc | 延迟 |
|--------|---------|----------|------|
| runc | 64.0 Gbps* | 基线 | 0.05 ms |
| **gVisor** | **59.4 Gbps** | **-31%** | **0.39 ms** |
| kata-qemu | 32.2 Gbps | -50% | 0.65 ms |
| kata-clh | 16.6 Gbps | -74% | 0.68 ms |

> *注：runc 吞吐在不同节点/测试条件下有差异，此处 gVisor 对比的 runc 基线为 86.0 Gbps（同节点 pod-to-pod），历史 Kata 测试的 runc 基线为 64.0 Gbps（跨节点）。

**关键发现：gVisor 网络吞吐优于两种 Kata 运行时。** gVisor 的网络栈（netstack）运行在用户态，但避免了 VM 的 virtio-net 设备模拟和 VMExit 开销。

---

## 3. 存储性能

### 3.1 测试结果

| 测试项 | gVisor | runc | gVisor / runc |
|--------|--------|------|---------------|
| **顺序写 1M** | 5,250 MiB/s | 137 MiB/s | ⚠️ 38x |
| **顺序读 1M** | 7,180 MiB/s | 99 MiB/s | ⚠️ 73x |
| **随机读 4K** | 448K IOPS | 3.3K IOPS | ⚠️ 136x |
| **随机写 4K** | 307K IOPS | 3.3K IOPS | ⚠️ 93x |

### 3.2 ⚠️ 重要说明：gVisor 存储数据不可直接对比

**gVisor 的数字严重失真。** 5,250 MiB/s 的顺序写速度远超 EBS gp3 的物理极限（~250 MiB/s），说明：

1. **gVisor 的 VFS 层（gofer + overlay）未真正执行 O_DIRECT**：虽然 fio 设置了 `direct=1`，但 gVisor 内部的文件系统实现可能将 I/O 缓存在 Sentry 进程的用户态内存中
2. **本质是内存带宽测试，不是磁盘 I/O 测试**
3. **与 Kata virtiofs 缓存问题类似**：之前 Test 5 中 Kata 的存储数据也因 virtiofs 缓存而不可比

**要获得真实的 gVisor 存储性能，需要挂载 EBS PVC（hostPath 或 CSI driver），绕过 overlay filesystem。**

### 3.3 runc 存储数据作为真实基线

runc 的数据是可靠的（直接走 host kernel + EBS）：
- 顺序写：137 MiB/s（EBS gp3 基线吞吐 125 MiB/s，加 burst 合理）
- 随机 4K：3.3K IOPS（EBS gp3 基线 3000 IOPS）

---

## 4. 综合对比总结

| 维度 | runc | gVisor | kata-qemu | kata-clh |
|------|------|--------|-----------|----------|
| **Pod 密度 (2xlarge)** | N/A | **14** | 7 | 13 |
| **网络吞吐** | 86 Gbps | **59 Gbps (-31%)** | 32 Gbps (-50%)* | 17 Gbps (-74%)* |
| **网络延迟** | 0.06 ms | **0.39 ms (6.4x)** | 0.65 ms (13x)* | 0.68 ms (13x)* |
| **存储 I/O** | 真实 | ⚠️ 缓存失真 | ⚠️ virtiofs 失真 | ⚠️ virtiofs 失真 |
| **隔离强度** | 无 | syscall 拦截 | **硬件 VM** | **硬件 VM** |
| **需要嵌套虚拟化** | 否 | **否** | 是 | 是 |
| **Pod Overhead** | 0 | **0** | 250 MiB | 200 MiB |

> *Kata 网络数据来自之前的跨节点测试（Test 3/4），测试条件略有差异。

---

## 5. 结论

1. **gVisor 网络性能显著优于 Kata**：吞吐 59.4 Gbps vs kata-qemu 32.2 Gbps / kata-clh 16.6 Gbps
2. **gVisor 网络延迟好于 Kata 但仍高于 runc**：0.39 ms vs kata 0.65 ms vs runc 0.06 ms
3. **存储测试因缓存失真不可比**：需 PVC 测试才能获得真实数据
4. **综合评估：gVisor 在密度、网络、资源效率三个维度均领先 Kata**，但安全隔离等级低于硬件 VM
