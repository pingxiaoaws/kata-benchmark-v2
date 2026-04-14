# gVisor (runsc) 满载压力测试：m8i.2xlarge (8 vCPU, 32 GiB)

**测试日期：** 2026-04-14
**运行时：** gVisor runsc release-20260406.0
**实例类型：** m8i.2xlarge（8 vCPU，32 GiB）
**节点：** ip-172-31-11-74.us-west-2.compute.internal
**隔离方式：** 用户态内核（syscall 拦截），无硬件虚拟化

---

## 测试结果

**稳定运行 14 个 Pod，Pod 15 失败（OOM/资源耗尽）。**

### 关键数据

| 指标 | 值 |
|------|-----|
| 最大稳定 Pod 数 | **14** |
| 失败点 | Pod 15 启动失败（Failed） |
| 停止原因 | 内存耗尽（14 pods 已用 93% 节点内存） |
| 调度器理论上限 | 14 pods（29901 MiB / 2048 MiB = 14.6） |
| **理论值达成率** | **100%**（14/14） |

### 每 Pod 指标趋势

| Pod # | 节点 CPU 使用 | 节点内存使用 | 内存占比 | 全部 Pod 状态 | 重启次数 |
|-------|-------------|------------|---------|-------------|---------|
| 1 | 7796m (98%) | 2770 MiB (9%) | 9% | OK | 0 |
| 2 | 8000m (101%) | 4706 MiB (15%) | 15% | OK | 0 |
| 4 | 7998m (101%) | 8671 MiB (28%) | 28% | OK | 0 |
| 7 | 8002m (101%) | 14386 MiB (48%) | 48% | OK | 0 |
| 10 | 8002m (101%) | 20261 MiB (67%) | 67% | OK | 0 |
| 12 | 8002m (101%) | 23955 MiB (80%) | 80% | OK | 0 |
| 14 | 8001m (101%) | 27949 MiB (93%) | 93% | OK | 0 |

---

## 工作负载规格（每 Pod，Guaranteed QoS）

| 容器 | CPU | 内存 | stress-ng 参数 |
|------|-----|------|---------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |

**每 Pod 合计：** 450m CPU，2048 MiB 内存（无 Pod Overhead）

---

## 与 Kata 运行时对比（同机型 m8i.2xlarge）

| 运行时 | 隔离方式 | Pod Overhead | 稳定 Pod 数 | 理论上限 | 达成率 | 失败模式 |
|--------|---------|-------------|------------|---------|--------|---------|
| **gVisor** | 用户态内核 | **0** | **14** | 14 | **100%** | Pod 15 Failed |
| kata-clh | 轻量 VM (CLH) | 200 MiB | 13 | 13 | 100% | Pod 14 调度器拒绝 |
| kata-qemu | 完整 VM (QEMU) | 250 MiB | 7 | 12 | 58% | Pod 8 OOM restart |

### 分析

1. **gVisor 密度最高**：14 pods，比 kata-qemu 多 100%，比 kata-clh 多 8%
2. **零 overhead**：gVisor 没有 VM 进程，没有 guest kernel 内存开销，所有内存都给容器用
3. **100% 理论达成率**：调度器理论上限 14 pods，实际跑了 14 pods，完美匹配
4. **内存利用率极高**：14 pods 时节点内存已用 93%，几乎榨干

### 为什么 gVisor 密度 > kata-clh？

虽然 kata-clh 也达到了 100% 理论值（13/13），但 kata-clh 有 200 MiB Pod Overhead，导致调度器理论上限只有 13。gVisor 没有 overhead，理论上限就是 14，所以多一个 pod。

### 为什么 gVisor 密度 >> kata-qemu？

kata-qemu 问题不仅是 250 MiB overhead，更重要的是：
- **QEMU 进程的实际内存消耗远超 overhead 声明**：每个 VM 的 QEMU 进程占用大量 host 内存（RSS ~400-500 MiB），但 cgroup 和调度器看不到这部分
- **VMExit + nested page table walk 导致内存压力放大**：在嵌套虚拟化环境下，QEMU 设备模拟触发大量 VMExit，加上 TLB miss 时的 24 次内存访问，导致实际内存带宽需求远高于账面值

gVisor 完全绕过了这些问题 — 没有 VM，没有 hypervisor，没有 EPT page walk。

---

## 注意事项

1. **安全隔离等级不同**：gVisor（用户态 syscall 拦截）vs Kata（硬件 VM 隔离），安全边界强度不可直比
2. **syscall 兼容性**：gVisor 不支持所有 Linux syscall，某些应用可能需要适配
3. **网络/存储性能**：详见 [network-storage-benchmark.md](network-storage-benchmark.md)

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload-gvisor.sh` | 测试脚本 |
| `results-fullload-gvisor.csv` | 逐 Pod 详细数据 |
| `test-fullload-gvisor.log` | 完整测试日志 |
| `README.md` | 本文档 |
