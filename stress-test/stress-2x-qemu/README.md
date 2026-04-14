# 最大 Pod 密度测试：kata-qemu 全压满 — m8i.2xlarge（嵌套虚拟化）

**日期：** 2026-04-14 02:28–02:44 UTC  
**结果：7 个 Pod 在 CPU+内存全压满下稳定运行，第 8 个 Pod 触发 4 次容器 restart**

## 1. 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-30-148.us-west-2.compute.internal |
| 实例类型 | **m8i.2xlarge**（8 vCPU，32 GiB） |
| 虚拟化 | **嵌套**（EC2 bare-metal-equivalent 上的 KVM） |
| 节点可调度资源 | cpu=7910m，memory=29901 MiB |
| RuntimeClass | kata-qemu |
| Pod Overhead | cpu=100m，memory=250Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s 版本 | v1.34.4-eks |
| 压测工具 | polinux/stress-ng（CPU 95% 负载 + vm-keep） |

## 2. Pod 规格（Guaranteed QoS，request = limit）

| 容器 | CPU | 内存 | stress-ng 参数 |
|------|-----|------|---------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |
| **容器合计** | **450m** | **2048 MiB** | **1750 MiB vm-bytes** |
| **+ RuntimeClass overhead** | **+100m** | **+250 MiB** | |
| **调度器视角（每 Pod）** | **550m** | **2298 MiB** | |

## 3. 理论最大值

```
节点可调度内存:     29901 MiB
系统 Pod 请求:      -  150 MiB
可用于测试 Pod:      29751 MiB

每 Pod（含 overhead）: 2298 MiB
内存上限: floor(29751 / 2298) = 12

节点可调度 CPU:      7910m
系统 Pod 请求:       - 190m
可用于测试 Pod:       7720m

每 Pod（含 overhead）:  550m
CPU 上限: floor(7720 / 550) = 14

理论最大值 = 12 个 Pod（内存受限）
```

## 4. 结果

### 逐 Pod 指标

| Pod | 就绪(s) | 节点CPU | CPU% | 节点内存 | 内存% | stress CPU | stress 内存(MiB) | Restart | 状态 |
|-----|---------|---------|------|----------|-------|------------|-----------------|---------|------|
| 1 | 9 | 378m | 4% | 2804Mi | 9% | 451m | 1782 | 0 | OK |
| 2 | 7 | 805m | 10% | 4987Mi | 16% | 452m | 1807 | 0 | OK |
| 3 | 6 | 1412m | 17% | 7077Mi | 23% | 451m | 1832 | 0 | OK |
| 4 | 7 | 1829m | 23% | 9300Mi | 31% | 452m | 1807 | 0 | OK |
| 5 | 7 | 2195m | 27% | 11497Mi | 38% | 450m | 1807 | 0 | OK |
| 6 | 7 | 2687m | 33% | 13794Mi | 46% | 450m | 1832 | 0 | OK |
| 7 | 7 | 2872m | 36% | 15916Mi | 53% | 452m | 1832 | 0 | OK |
| **8** | **7** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **4** | **FAIL** |

### 每 Pod 增量开销（从稳定区间 1–7 推导）

| 指标 | 每 Pod 增量 | 备注 |
|------|------------|------|
| kubectl top node 内存 | ~2185 MiB | cAdvisor 看到 QEMU sandbox cgroup |
| kubectl top node CPU | ~416m | 包含 stress-ng + QEMU vCPU 调度开销 |
| stress-ng CPU/Pod | ~451m | 高度一致：450–452m |
| stress-ng 内存/Pod | ~1810 MiB | 高度一致：1782–1832 MiB |

### 汇总

| 指标 | 值 |
|------|-----|
| **最大稳定 Pod 数** | **7** |
| 调度器理论上限 | 12（内存受限） |
| 差距 | 5 个 Pod（比理论少 42%） |
| 失败触发 | Pod 8 — 4 次容器 restart |
| 7 Pod 时节点 CPU | 36% |
| 7 Pod 时节点内存 | 53% |

## 5. 分析

### 5.1 与 4xlarge 对比

| 维度 | m8i.2xlarge | m8i.4xlarge |
|------|-------------|-------------|
| vCPU | 8 | 16 |
| 内存 | 32 GiB | 64 GiB |
| 稳定 Pod 数 | **7** | **14** |
| 理论上限 | 12 | 25 |
| 利用率 vs 理论 | 58% | 56% |
| 失败时节点内存 | 53% | 54% |
| 失败模式 | Pod 8 restart | Pod 15 restart |

关键发现：**Pod 密度精确线性扩展** — 2xlarge 7 个，4xlarge 14 个，正好 2 倍。这说明嵌套虚拟化的 EPT 争抢瓶颈与 vCPU 数成正比。

### 5.2 与 kata-clh 同机型对比（m8i.2xlarge）

| 维度 | kata-qemu | kata-clh | 差异 |
|------|-----------|----------|------|
| 稳定 Pod 数 | 7 | **13** | **+86%** |
| 理论上限 | 12 | 13 | +8% |
| 利用率 vs 理论 | 58% | **100%** | +42pp |
| 失败时节点内存 | 53% | 95% | CLH 利用率更高 |
| 失败模式 | VM restart | 调度器拒绝 | CLH 更优雅 |

kata-clh 在全压满场景下密度几乎是 kata-qemu 的 2 倍。

## 6. 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload.sh` | 测试脚本 |
| `results-fullload.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test-fullload.log` | 完整测试执行日志 |
| `README.md` | 本分析文档 |
