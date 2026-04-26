# kata-fc Full-Load Max Pod Density — m7g.metal (Bare Metal)

**日期:** 2026-04-26 01:21–02:02 UTC  
**结果: 24 个 Pod 在 CPU+内存全压满下稳定运行，第 25 个 Pod Pending（内存不足）**

## 1. 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-22-115.us-west-2.compute.internal |
| 实例类型 | **m7g.metal**（64 vCPU, 256 GiB, Graviton3） |
| 虚拟化 | **裸金属**（无嵌套虚拟化） |
| 架构 | aarch64 (ARM) |
| 节点可调度资源 | cpu=63770m, memory=248750 MiB |
| RuntimeClass | kata-fc (Firecracker) |
| Pod Overhead | cpu=250m, memory=130Mi |
| Kata VM Kernel | 6.18.12 |
| K8s 版本 | v1.34.6-eks |
| 压测方式 | busybox (CPU: while loop; Memory: dd to /dev/shm) |

> **注意**: kata-fc devmapper snapshotter 不支持多层镜像（alpine、nginx、stress-ng 均失败），只能使用单层镜像 busybox。

## 2. Pod 规格（Guaranteed QoS, request = limit）

| 容器 | CPU | 内存 | 压测方式 |
|------|-----|------|---------|
| gateway | 150m | 1 GiB | dd 900M to /dev/shm + CPU while loop |
| config-watcher | 100m | 256 MiB | dd 200M to /dev/shm + CPU while loop |
| envoy | 100m | 256 MiB | dd 200M to /dev/shm + CPU while loop |
| wazuh | 100m | 512 MiB | dd 450M to /dev/shm + CPU while loop |
| **容器合计** | **450m** | **2048 MiB** | **1750 MiB /dev/shm** |
| **+ RuntimeClass overhead** | **+250m** | **+130 MiB** | |
| **调度器视角（每 Pod）** | **700m** | **2178 MiB** | |

## 3. 理论最大值

```
节点可调度内存:      248750 MiB
Baseline 已用:      -204626 MiB (82%)
可用于测试 Pod:       44124 MiB

每 Pod 实际内存增量:   ~2004 MiB
内存上限: floor(44124 / 2004) = ~22

节点可调度 CPU:       63770m
系统 Pod 请求:        - 190m
可用于测试 Pod:        63580m

每 Pod（含 overhead）: 700m
CPU 上限: floor(63580 / 700) = 90

理论最大值 = ~22 个 Pod（内存受限，因 baseline 高占用）
实际结果 = 24 个 Pod（比预估略好，因 OS 会回收部分缓存）
```

## 4. 结果

### 逐 Pod 指标

| Pod | 节点 CPU | CPU% | 节点内存 | Mem% | Pod CPU | Pod Mem(MiB) | Restart | 状态 |
|-----|---------|------|---------|------|---------|-------------|---------|------|
| 1 | 908m | 1% | 206684Mi | 83% | 452m | 1756 | 0 | OK |
| 2 | 1316m | 2% | 208688Mi | 83% | 451m | 1756 | 0 | OK |
| 3 | 1731m | 2% | 210715Mi | 84% | 452m | 1755 | 0 | OK |
| 4 | 2245m | 3% | 212744Mi | 85% | 452m | 1755 | 0 | OK |
| 5 | 2628m | 4% | 214771Mi | 86% | 452m | 1756 | 0 | OK |
| 6 | 2985m | 4% | 216821Mi | 87% | 453m | 1756 | 0 | OK |
| 7 | 3517m | 5% | 218860Mi | 87% | 452m | 1755 | 0 | OK |
| 8 | 3899m | 6% | 220886Mi | 88% | 452m | 1756 | 0 | OK |
| 9 | 4322m | 6% | 222919Mi | 89% | 452m | 1755 | 0 | OK |
| 10 | 4838m | 7% | 224938Mi | 90% | 452m | 1756 | 0 | OK |
| 11 | 5355m | 8% | 226978Mi | 91% | 452m | 1755 | 0 | OK |
| 12 | 5921m | 9% | 229005Mi | 92% | 452m | 1755 | 0 | OK |
| 13 | 6535m | 10% | 231055Mi | 92% | 454m | 1756 | 0 | OK |
| 14 | 6963m | 10% | 233056Mi | 93% | 453m | 1755 | 0 | OK |
| 15 | 7460m | 11% | 235234Mi | 94% | 453m | 1756 | 0 | OK |
| 16 | 7935m | 12% | 237263Mi | 95% | - | - | 0 | OK |
| 17 | 8333m | 13% | 239315Mi | 96% | 450m | 1755 | 0 | OK |
| 18 | 8841m | 13% | 241327Mi | 97% | 453m | 1756 | 0 | OK |
| 19 | 9262m | 14% | 243104Mi | 97% | 451m | 1755 | 0 | OK |
| 20 | 9697m | 15% | 244627Mi | 98% | 452m | 1755 | 0 | OK |
| 21 | 10147m | 15% | 246577Mi | 99% | 454m | 1755 | 0 | OK |
| 22 | 10473m | 16% | 248637Mi | 99% | 452m | 1756 | 0 | OK |
| 23 | 11073m | 17% | 250767Mi | 100% | 454m | 1756 | 0 | OK |
| 24 | 11419m | 17% | 252634Mi | 101% | 451m | 1756 | 0 | OK |
| **25** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **0** | **PENDING** |

### 每 Pod 增量开销

| 指标 | 每 Pod 增量 | 备注 |
|------|------------|------|
| kubectl top node 内存 | ~2004 MiB | Firecracker VM + 容器实际使用 |
| kubectl top node CPU | ~452m | 精确吃满容器 request |
| Pod 内 CPU | ~452m | while loop 被 cgroup 限制 |
| Pod 内内存 | ~1756 MiB | /dev/shm 分配 (900+200+200+450) |
| **Firecracker VM overhead** | **~248 MiB** | 2004 - 1756 = 248 MiB（远超声明的 130Mi） |

### 汇总

| 指标 | 值 |
|------|-----|
| **最大稳定 Pod 数** | **24** |
| CPU 理论上限 | 90（CPU 受限） |
| 内存理论上限 | ~22（内存受限） |
| 失败触发 | Pod 25 Pending |
| 24 Pod 时节点 CPU | 17% |
| 24 Pod 时节点内存 | **101%** |
| 失败原因 | **内存不足** |

## 5. 分析

### 5.1 与 kata-qemu m8i.2xlarge 对比

| 维度 | kata-fc m7g.metal | kata-qemu m8i.2xlarge | 倍数 |
|------|-------------------|----------------------|------|
| vCPU | 64 | 8 | 8x |
| 内存 | 256 GiB | 32 GiB | 8x |
| 稳定 Pod 数 | **24** | **7** | **3.4x** |
| 瓶颈 | 内存 | 内存（推测） | - |
| 失败模式 | Pending（调度器拒绝）| Restart | FC 更优雅 |
| CPU 利用率 | 17% | 36% | - |
| 内存利用率 | 101% | 53% | - |
| VM overhead/pod | ~248 MiB | ~2185 MiB（含 QEMU） | **FC 省 8.8x** |

### 5.2 Firecracker 实际 overhead vs 声明

| 项目 | 声明 (RuntimeClass) | 实测 |
|------|---------------------|------|
| CPU overhead | 250m | ~2m（几乎无额外开销） |
| Memory overhead | 130Mi | **~248 MiB**（严重低估） |

**建议**: 将 kata-fc RuntimeClass 的内存 overhead 从 130Mi 调高到 **300Mi**，更准确反映实际。

### 5.3 Baseline 内存高占用问题

节点 baseline（0 pods）就已用 205 GiB (82%)。这包括：
- kata-deploy daemonset
- 内核 page cache / slab
- containerd + snapshotter

如果能减少 baseline 内存占用，pod 密度可以显著提高。

### 5.4 kata-fc 镜像限制

**kata-fc devmapper snapshotter 只支持单层镜像**（busybox）。多层镜像（alpine、nginx、stress-ng）全部报错：
```
failed to extract layer: failed to get reader from content store: content digest ... not found
```
这是生产环境使用 kata-fc 的重大限制。

## 6. 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload.sh` | 测试脚本 |
| `results-fullload.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test-fullload.log` | 完整测试执行日志 |
| `README.md` | 本分析文档 |
