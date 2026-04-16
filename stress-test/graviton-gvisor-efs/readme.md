# Graviton gVisor + EFS 满载测试

## 测试概述

在 Graviton (arm64) 节点上验证 gVisor 运行时 + EFS 挂载的 Pod 密度和稳定性，并与无 EFS 的 gVisor 基线对比。

## 环境

| 项目 | 值 |
|------|-----|
| 节点 | ip-172-31-9-46.us-west-2.compute.internal |
| 实例类型 | m7g.2xlarge (Graviton, arm64) |
| 资源 | 8 vCPU, 32 GiB 内存 |
| Allocatable | 7,910m CPU, 30,500 MiB 内存 |
| 运行时 | gVisor (runsc) |
| 存储 | EFS (efs-sc, TLS, dynamic provisioning) |
| 每 Pod 工作负载 | 4 × stress-ng 容器 (总计 450m CPU request, 2,048 MiB mem request) + EFS PVC |
| 测试日期 | 2026-04-15 |

### 对比基线

- **gVisor 无 EFS**: 同脚本、同节点，2026-04-14 执行，结果见 `../stress-2x-gvisor/`

## 结果摘要

### Graviton gVisor + EFS（2026-04-15）

| Pods | 节点内存占用 | 内存% | 每 Pod 内存 delta | stress-ng CPU | stress-ng Mem | EFS 挂载 |
|------|------------|-------|------------------|---------------|---------------|----------|
| 1 | 2,826 MiB | 9% | — | 7,555m | 1,848 MiB | ✅ OK |
| 2 | 4,748 MiB | 15% | 1,922 MiB | 6,890m | 1,848 MiB | ✅ OK |
| 3 | 6,827 MiB | 22% | 2,079 MiB | 6,819m | 1,848 MiB | ✅ OK |
| 4 | 8,544 MiB | 28% | 1,717 MiB | 6,325m | 1,823 MiB | ✅ OK |
| 5 | 10,690 MiB | 35% | 2,146 MiB | 5,747m | 1,798 MiB | ✅ OK |
| 6 | 12,356 MiB | 40% | 1,666 MiB | 5,799m | 1,798 MiB | ✅ OK |
| 7 | 14,466 MiB | 47% | 2,110 MiB | 5,227m | 1,798 MiB | ✅ OK |
| 8 | 16,494 MiB | 54% | 2,028 MiB | 4,523m | 1,798 MiB | ✅ OK |
| 9 | 18,459 MiB | 60% | 1,965 MiB | 4,769m | 1,823 MiB | ✅ OK |
| 10 | 20,329 MiB | 66% | 1,870 MiB | 3,903m | 1,798 MiB | ✅ OK |
| 11 | 22,286 MiB | 73% | 1,957 MiB | 5,031m | 1,823 MiB | ✅ OK |
| 12 | 24,059 MiB | 78% | 1,773 MiB | 3,835m | 1,848 MiB | ✅ OK |
| 13 | 26,026 MiB | 85% | 1,967 MiB | 4,396m | 1,798 MiB | ✅ OK |
| 14 | 28,169 MiB | 92% | 2,143 MiB | 3,779m | 1,823 MiB | ✅ OK |

### gVisor 无 EFS 基线（2026-04-14）

| Pods | 节点内存占用 | 内存% | 每 Pod 内存 delta | stress-ng CPU | stress-ng Mem |
|------|------------|-------|------------------|---------------|---------------|
| 1 | 2,770 MiB | 9% | — | 7,308m | 1,835 MiB |
| 7 | 14,386 MiB | 48% | ~1,936 MiB/pod | 4,591m | 1,838 MiB |
| 14 | 27,949 MiB | 93% | ~1,937 MiB/pod | 3,165m | 1,857 MiB |

## 关键结论

### 1. 稳定性：14 Pods 满载零故障

- **0 restarts, 0 crash**，跑到节点内存 92%
- 对比 kata-clh 在类似负载下会 crash（见 Test 5b）

### 2. EFS 挂载对性能几乎无影响

| 指标 | 无 EFS (4/14) | 有 EFS (4/15) | 差异 |
|------|-------------|-------------|------|
| 14 Pods 内存占用 | 27,949 MiB (93%) | 28,169 MiB (92%) | +220 MiB (+0.8%) |
| 每 Pod 平均 delta | ~1,937 MiB | ~1,949 MiB | +12 MiB |
| 14 Pods stress CPU | 3,165m | 3,779m | +19% (波动范围内) |

EFS PVC 动态挂载仅增加 ~12 MiB/pod 的边际内存开销。

### 3. gVisor Sandbox Overhead

- **每 Pod 内存 delta**: ~1,910–1,940 MiB
- **stress-ng 自身占用**: ~1,830 MiB
- **gVisor sandbox overhead**: ~80–110 MiB/pod
- 对比：kata-qemu ~207 MiB/pod, kata-clh ~167 MiB/pod

### 4. 运行时 Pod Overhead 对比

| 运行时 | 每 Pod Overhead | 满载稳定性 | 备注 |
|--------|----------------|-----------|------|
| gVisor (runsc) | ~80–110 MiB | 14 pods, 0 crash | ✅ 最轻量 |
| kata-clh | ~167 MiB | 高负载 crash | ⚠️ |
| kata-qemu | ~207 MiB | 稳定 | ✅ |

## 文件说明

| 文件 | 说明 |
|------|------|
| `max-pod-test-graviton-gvisor-efs.sh` | 测试脚本 |
| `results-graviton-gvisor-efs.csv` | 原始 CSV 数据 |
| `test-graviton-gvisor-efs.log` | 完整执行日志 |

## 复现

```bash
# 在 Graviton gVisor 节点上运行
./max-pod-test-graviton-gvisor-efs.sh ip-172-31-9-46.us-west-2.compute.internal
```

前置条件：
- 节点已安装 gVisor (runsc) 并配置 RuntimeClass
- EFS CSI driver 已部署，StorageClass `efs-sc` 已创建
- 节点有 `runtime=gvisor` label 和 `gvisor=true:NoSchedule` taint
