# 最大 Pod 密度测试：kata-clh 全压满 — m8i.4xlarge（嵌套虚拟化）

**日期：** 2026-04-14 03:33–04:21 UTC  
**结果：24 个 Pod 在 CPU+内存全压满下稳定运行（节点内存 90%），测试正常完成**

## 1. 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-18-59.us-west-2.compute.internal |
| 实例类型 | **m8i.4xlarge**（16 vCPU，64 GiB） |
| 虚拟化 | **嵌套**（EC2 bare-metal-equivalent 上的 KVM） |
| 节点可调度资源 | cpu=15890m，memory=58567 MiB |
| RuntimeClass | **kata-clh** |
| Pod Overhead | cpu=100m，memory=200Mi |
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
| **容器合计** | **450m** | **2048 MiB** | |
| **+ RuntimeClass overhead** | **+100m** | **+200 MiB** | |
| **调度器视角（每 Pod）** | **550m** | **2248 MiB** | |

## 3. 结果汇总

| 指标 | 值 |
|------|-----|
| 最大稳定 Pod 数 | **24** |
| 最终节点 CPU 请求 | 9907m（62%） |
| 最终节点内存请求 | 52983 MiB（90%） |
| 总 restart 数 | 0 |
| 所有 Pod 正常 | ✅ |
| 测试时长 | ~47 分钟 |

## 4. 关键发现

- kata-clh 在 m8i.4xlarge 上全压满跑了 **24 个 Pod**，而 kata-qemu 同条件只有 **14 个**（Pod 15 出现 restart）
- CLH 更低的 Pod Overhead（200Mi vs 250Mi）允许更高密度
- 24 个 Pod 时节点内存达 90% — 接近极限
- 整个测试过程中**无任何崩溃或 restart**

## 5. 跨测试对比

| 测试 | 运行时 | 实例 | 最大稳定 Pod 数 | 限制因素 |
|------|--------|------|----------------|---------|
| stress-4x-qemu | kata-qemu | m8i.4xlarge | 14 | Pod 15 restart |
| **stress-4x-clh** | **kata-clh** | **m8i.4xlarge** | **24** | **内存 90%** |
| stress-2x-qemu | kata-qemu | m8i.2xlarge | 6 | Pod 7 OOM |
| stress-2x-clh | kata-clh | m8i.2xlarge | 13 | Pod 14 Failed |

## 6. 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload-v2.sh` | 测试脚本（支持运行时参数） |
| `results-fullload-kata-clh.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test-fullload-kata-clh.log` | 完整测试执行日志 |
| `README.md` | 本分析文档 |
