# Kata Containers 嵌套虚拟化性能基准测试 v2

## 概述

评估 Kata Containers（kata-qemu / kata-clh）在 EKS 嵌套虚拟化环境下的性能开销、内存占用和超卖稳定性。

**测试日期**: 2026-04-03 ~ 2026-04-07  
**集群**: test-s4, Amazon EKS 1.34, us-west-2  
**Operator**: OpenClaw Operator v0.22.2  
**运行时**: runc (containerd 2.1.5), kata-qemu, kata-clh  
**节点**: 9x m8i.4xlarge + 1x r8i.2xlarge  

---

## 核心发现

| 维度 | Kata 开销 | 评级 |
|------|----------|------|
| CPU 计算 | <1% | ✅ 优秀 |
| 内存带宽 | <5% | ✅ 优秀 |
| 启动时间 | +18-20s (+37%) | ⚠️ 中等 |
| 网络吞吐 | -50% | 🔴 严重 |
| 网络延迟 | 13x (0.06→0.8ms) | 🔴 严重 |
| 内存固定开销 | ~200-210 MiB/Pod | ⚠️ 中等 |
| kubectl 可见性 | cgroup 报 0 | 🔴 盲区 |
| 超卖稳定性 | 200% 超卖 2h 零 OOM | ✅ 优秀 |

**推荐**: kata-qemu 用于生产，kata-clh 高负载不稳定不推荐。

---

## 测试列表

| # | 测试 | 关键结论 |
|---|------|---------|
| 1 | 单 Pod 冷启动 | Kata 热启动 +18-20s (+37%) |
| 2 | 节点饱和启动 | Kata 波动大 (65-104s)，runc 稳定 |
| 3 | 集群满载启动 | kata-qemu 一致稳定 ~68s |
| 4 | 运行时对比 | 稳态资源三者一致 (~1m CPU, ~400Mi MEM) |
| 5 | 超卖稳定性 | 16 kata-qemu VMs / 8 vCPU，2h 零 OOM |
| 6 | 运行时开销 | CPU <1%，网络 -50%，I/O 有 cache 干扰 |
| 7 | 内存占用画像 | ~200 MiB/Pod 固定税，kubectl 完全不可见 |

---

## 目录结构

```
kata-benchmark-v2/
├── README.md                           ← 本文件
├── kata-benchmark-report.pptx          ← PPT 演示报告 (15页)
├── results/
│   ├── kata-benchmark-v2-full-report.md  ← 完整 Markdown 报告
│   ├── v2-benchmark-summary.md           ← Test 1-5 摘要
│   ├── v2-test6-summary.md               ← Test 6 摘要
│   ├── v2-test7-summary.md               ← Test 7 摘要
│   ├── v2-test1-boot-time.csv            ← 冷启动数据 (15条)
│   ├── v2-test2-saturated-boot-time.csv  ← 饱和启动数据 (9条)
│   ├── v2-test3-multi-node-boot-time.csv ← 满载启动数据 (9条)
│   ├── v2-test4-runtime-comparison.csv   ← 运行时对比 (3条)
│   ├── v2-test5-oversell-stability.csv   ← 超卖监控 (384条)
│   ├── v2-test6-cpu.csv                  ← CPU benchmark (15条)
│   ├── v2-test6-memory.csv               ← 内存带宽 (15条)
│   ├── v2-test6-disk-seqwrite.csv        ← 磁盘顺序写 (9条)
│   ├── v2-test6-disk-randio.csv          ← 磁盘随机 IO (9条)
│   ├── v2-test6-network.csv              ← 网络性能 (9条)
│   ├── v2-test6-host-overhead.csv        ← Host CPU 开销 (9条)
│   ├── v2-test6-stress.csv               ← 综合负载 (3条)
│   ├── v2-test7a-idle-memory-delta.csv   ← 内存 delta (6条)
│   ├── v2-test7b-qemu-rss.csv           ← QEMU RSS (9条)
│   ├── v2-test7c-cgroup-vs-top.csv       ← cgroup 对比 (2条)
│   ├── v2-test7d-stress-overhead.csv     ← 内存压力 (8条)
│   └── v2-test7e-multi-pod-linearity.csv ← 多 Pod 线性 (8条)
├── scripts/
│   ├── bench-v2-test7.sh                 ← Test 7 主脚本
│   └── bench-v2-test7-remaining.sh       ← Test 7 补充脚本
├── charts/                               ← 图表图片
├── docs/                                 ← 补充文档
└── generate_ppt.py                       ← PPT 生成脚本
```

---

## 快速阅读

1. **完整报告**: `results/kata-benchmark-v2-full-report.md` — 包含所有测试的目的、方法、结果、分析、生产建议
2. **PPT 演示**: `kata-benchmark-report.pptx` — 15 张幻灯片，适合分享和汇报
3. **原始数据**: `results/v2-test*.csv` — 可用于自定义分析和可视化

---

## 生产建议速查

**容量规划**:
```
每节点 Kata Pod 数 = (节点内存 - 2GB) / (应用内存 + 210MiB)
m8i.4xlarge: (64GB - 2GB) / (1GB + 210MB) ≈ 51 pods
```

**监控**: 不要依赖 `kubectl top`，必须用 host 级监控（Node Exporter）

**启动优化**: 预热节点、分批启动、调大 startup probe

**运行时选择**: AI Agent → kata-qemu ✅ | 网络密集 → runc | 数据持久化 → runc
