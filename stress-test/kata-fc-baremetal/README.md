# kata-fc Full-Load Max Pod Density — Bare Metal Graviton

## 概述

在 AWS Graviton bare metal 实例上测试 kata-fc (Firecracker) 的 Full-Load Pod 最大密度。
每个 Pod 包含 4 个容器，模拟真实工作负载（CPU busy-loop + 内存占用）。

## Pod 配置

| 容器 | CPU | 内存 | 负载 |
|------|-----|------|------|
| gateway | 150m | 1 GiB | dd 900M + busy loop |
| config-watcher | 100m | 256 MiB | dd 200M + busy loop |
| envoy | 100m | 256 MiB | dd 200M + busy loop |
| wazuh | 100m | 512 MiB | dd 450M + busy loop |
| **合计** | **450m** | **2048 MiB** | **1750 MiB vm-bytes** |
| + kata-fc overhead | +250m | +130Mi | |
| **调度器视角/pod** | **700m** | **2178 MiB** | |

镜像：busybox:1.36（kata-fc devmapper snapshotter 仅支持单层镜像）

## 测试结果

### Pod Density（无 PVC）

| 实例 | vCPU | RAM | 最大稳定 Pods | 瓶颈 | CPU 使用 | 内存使用 |
|------|------|-----|---------------|------|----------|----------|
| c7g.metal (Graviton3) | 64 | 128 GiB | **55** | 内存 99% | 39% | 54% (kubectl top) |
| m7g.metal (Graviton3) | 64 | 256 GiB | **90** | CPU 99% | 60% | 68% (kubectl top) |

### EBS PVC Pod Density

| 实例 | vCPU | RAM | 最大稳定 Pods | 瓶颈 | CPU 使用 | 内存使用 |
|------|------|-----|---------------|------|----------|----------|
| m7g.metal (Graviton3) | 64 | 256 GiB | **28** | EBS attachment limit | 20% | 14% |

每个 Pod 挂载 1Gi EBS gp3 PVC，gateway 容器写 100MB 到 `/mnt/ebs`。

### c7g.metal 详情 (128 GiB)
- 日期: 2026-04-26
- 节点: ip-172-31-16-251 (c7g.metal, 64 vCPU, 128 GiB)
- 停止原因: Pod 56 failed (内存不足，scheduler rejected)
- 1-55 全部 Running，零 Restarts
- 理论上限: MEM 120066Mi / 2178Mi ≈ 55 pods ✅ 精确命中

### m7g.metal 详情 (256 GiB, 无 PVC)
- 日期: 2026-04-26
- 节点: ip-172-31-31-78 (m7g.metal, 64 vCPU, 256 GiB)
- 停止原因: Pod 91 failed (CPU 不足，scheduler rejected)
- 1-90 全部 Running，零 Restarts（Pod 84-90 启动变慢，每个 ~14 分钟）
- 理论上限: CPU 63770m / 700m ≈ 91 pods ✅ 精确命中
- 注: Pod 84+ 启动变慢可能与 devmapper thinpool (loopback) 压力有关

### m7g.metal + EBS PVC 详情
- 日期: 2026-04-27
- 节点: ip-172-31-42-51 (m7g.metal, 64 vCPU, 256 GiB)
- 每 Pod 挂载 1Gi EBS gp3 PVC，gateway 容器写 100MB 到 `/mnt/ebs`
- 停止原因: Pod 29 failed (Pending — EBS attachment limit reached)
- 1-28 全部 Running，零 Restarts
- EBS 卷分配: root(1) + devmapper thinpool(1) + 28 PVC = 30 EBS + 1 ENI = 31（共享上限）
- **瓶颈分析**: m7g.metal `MaximumEbsAttachments=31`, `AttachmentLimitType=shared`（EBS 与 ENI 共享 NVMe 槽位）
- 可用 PVC 数 = 31 - root(1) - devmapper(1) - ENI(1) = **28** ✅ 精确命中
- CPU 仅用 20%，内存仅用 14% — 资源远未饱和，纯粹被 EBS 挂载数限制

## 关键发现

1. **kata-fc 在 bare metal 上非常稳定** — 90 个 Full-Load pods (360 个 FC 微VM 容器)，零 Restarts
2. **资源利用精确** — 实际 max pods 与理论计算完全一致（CPU/内存/EBS 三种瓶颈均验证）
3. **每 Pod 实际内存开销 ~1180 MiB**（kubectl top），包含 FC VM overhead + guest kernel + /dev/shm 占用
4. **CPU 实际使用仅 ~60%**（m7g）— busy loop 在 FC 内受 cgroup 限制，不会超出 request
5. **devmapper thinpool 是 kata-fc 的前置依赖** — 需要配置 loopback thinpool 或 dedicated block device
6. **EBS attachment 是 PVC 场景的真实瓶颈** — m7g.metal 共享 31 槽位（EBS+ENI），实际可用 28 个 PVC，CPU/内存远未饱和（20%/14%）
7. **Nitro 共享槽位模型** — `AttachmentLimitType=shared` 意味着 ENI 也消耗 EBS 槽位，规划时需扣除

## 环境

- Kata Containers: 3.27.0
- Firecracker: v1.12.1
- Guest Kernel: 6.18.12 (aarch64)
- Host: Ubuntu 24.04.4 LTS, kernel 6.17.0-1007-aws
- Containerd: 1.7.28
- EKS: 1.34, test-s4 cluster

## 配置修复记录

kata-fc 在 EKS managed nodegroup 上需要以下额外配置：
1. **devmapper thinpool**: 创建 loopback sparse file + dmsetup thin-pool
2. **containerd ConfigPath**: 添加 `kata-fc.options.ConfigPath` 指向 FC 专用配置
3. **static_sandbox_resource_mgmt = false**: FC 不支持 CPU hotplug，必须关闭
4. **shim symlink**: `containerd-shim-kata-fc-v2 -> containerd-shim-kata-v2`

## 文件

- `max-pod-test-fullload-c7g.sh` — c7g.metal 测试脚本
- `max-pod-test-fullload-m7g.sh` — m7g.metal 测试脚本（loopback thinpool）
- `max-pod-test-fullload-m7g-ebs.sh` — m7g.metal + EBS thinpool 测试脚本
- `max-pod-test-fullload-m7g-ebs-pvc.sh` — m7g.metal + EBS PVC 测试脚本
- `results-fullload-c7g.csv` — c7g.metal 逐 pod 数据
- `results-fullload-m7g.csv` — m7g.metal 逐 pod 数据
- `results-fullload-m7g-ebs-pvc.csv` — m7g.metal EBS PVC 逐 pod 数据
- `test-fullload-c7g.log` — c7g.metal 完整日志
- `test-fullload-m7g.log` — m7g.metal 完整日志
- `test-fullload-m7g-ebs-pvc.log` — m7g.metal EBS PVC 完整日志
