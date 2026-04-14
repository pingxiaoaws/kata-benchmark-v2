# 最大 Pod 密度测试：kata-clh 全压满 — m8i.2xlarge（嵌套虚拟化）

**日期：** 2026-04-14 02:45–03:10 UTC  
**结果：13 个 Pod 在 CPU+内存全压满下稳定运行（达到调度器上限），第 14 个 Pod Failed**

## 1. 环境

| 属性 | 值 |
|------|-----|
| 节点 | ip-172-31-30-148.us-west-2.compute.internal |
| 实例类型 | **m8i.2xlarge**（8 vCPU，32 GiB） |
| 虚拟化 | **嵌套**（EC2 bare-metal-equivalent 上的 KVM） |
| 节点可调度资源 | cpu=7910m，memory=29901 MiB |
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

## 3. 理论最大值

```
节点可调度内存:     29901 MiB
系统 Pod 请求:      -  150 MiB
可用于测试 Pod:      29751 MiB

每 Pod（含 overhead）: 2248 MiB
内存上限: floor(29751 / 2248) = 13

节点可调度 CPU:      7910m
系统 Pod 请求:       - 190m
可用于测试 Pod:       7720m

每 Pod（含 overhead）:  550m
CPU 上限: floor(7720 / 550) = 14

理论最大值 = 13 个 Pod（内存受限）
```

## 4. 结果

### 逐 Pod 指标

| Pod | 就绪(s) | 节点 CPU | CPU% | 节点内存 | 内存% | stress CPU | stress 内存(MiB) | 状态 |
|-----|---------|----------|------|----------|-------|------------|-----------------|------|
| 1 | 7 | 620m | 7% | 2998Mi | 10% | 452m | 1807 | OK |
| 2 | 7 | 1055m | 13% | 5075Mi | 16% | 451m | 1807 | OK |
| 3 | 7 | 1448m | 18% | 7148Mi | 23% | 452m | 1807 | OK |
| 4 | 7 | 1897m | 23% | 9303Mi | 31% | 451m | 1807 | OK |
| 5 | 7 | 2537m | 32% | 11427Mi | 38% | 453m | 1807 | OK |
| 6 | 7 | 2917m | 36% | 13558Mi | 45% | 453m | 1832 | OK |
| 7 | 7 | 3321m | 41% | 15666Mi | 52% | 453m | 1807 | OK |
| 8 | 7 | 3675m | 46% | 17818Mi | 59% | 451m | 1818 | OK |
| 9 | 7 | 3963m | 50% | 20041Mi | 67% | 452m | 1782 | OK |
| 10 | 7 | 4448m | 56% | 22298Mi | 74% | 451m | 1832 | OK |
| 11 | 7 | 4746m | 60% | 24395Mi | 81% | 453m | 1832 | OK |
| 12 | 7 | 5088m | 64% | 26543Mi | 88% | 452m | 1807 | OK |
| 13 | 7 | 5222m | 66% | 28616Mi | 95% | 453m | 1782 | OK |
| **14** | — | — | — | — | — | — | — | **Failed** |

### 每 Pod 增量开销

| 指标 | 每 Pod 增量 | 备注 |
|------|------------|------|
| kubectl top node 内存 | ~2130 MiB | cAdvisor：QEMU sandbox cgroup |
| kubectl top node CPU | ~384m | 5 vCPU，stress 驱动 ~452m |
| stress-ng CPU/Pod | ~452m | 13 个 Pod 间高度一致 |
| stress-ng 内存/Pod | ~1807 MiB | 高度一致 |
| VM 启动时间 | 7s | 即使到 13 个 Pod 也无退化 |

### 汇总

| 指标 | 值 |
|------|-----|
| **最大稳定 Pod 数** | **13** |
| 调度器理论上限 | 13（内存受限） |
| 差距 | **0 个 Pod（100% 达到调度器上限！）** |
| 失败触发 | Pod 14 — 调度器拒绝（内存不足） |
| 13 Pod 时节点 CPU | 66% |
| 13 Pod 时节点内存 | 95% |
| 所有 Pod 总 restart | 0 |

## 5. 分析

### 5.1 kata-clh 达到了调度器上限

这是所有测试中唯一一次 **100% 达到调度器理论上限** 的结果。13 个 Pod 全部稳定，0 次 restart，Pod 14 因调度器内存不足被拒绝（不是 VM crash）。

### 5.2 与 kata-qemu 同机型对比（m8i.2xlarge）

| 维度 | kata-qemu | kata-clh | 差异 |
|------|-----------|----------|------|
| 稳定 Pod 数 | 7 | **13** | **+86%** |
| 理论上限 | 12 | 13 | +8%（overhead 更小） |
| 利用率 vs 理论 | 58% | **100%** | +42pp |
| 失败时节点内存% | 53% | 95% | 更高利用率 |
| 失败时节点 CPU% | 36% | 66% | 更高利用率 |
| 失败模式 | VM crash（4 次 restart） | 调度器拒绝 | 更优雅 |
| 每 Pod cAdvisor 内存 Δ | ~2161 MiB | ~2130 MiB | CLH 略小 |
| VM 启动时间 | 6-7s | 7s | 相当 |

### 5.3 kata-clh 表现更好的原因

1. **Cloud Hypervisor 更轻量**：CLH 进程本身 RSS 比 QEMU 小 ~40 MiB（Test 9 数据：167 MiB vs 207 MiB）
2. **更好的嵌套虚拟化兼容性**：CLH 仅使用 virtio 设备，大幅减少 VMExit 频率，降低嵌套虚拟化下的 nested page walk 和 vCPU 调度争抢
3. **内存效率更高**：Pod overhead 只有 200 MiB（vs QEMU 250 MiB），每 Pod 节省 50 MiB
4. **无级联 crash**：即使到 13 Pod（95% 内存），所有 VM 仍然稳定运行

### 5.4 之前已知的 kata-clh 弱点

之前 Test 5b 和 Test 10 发现 kata-clh 在高负载下会 crash。但那些测试是**超卖场景**（memory overcommit），而本测试是 Guaranteed QoS（request = limit）。在不超卖的情况下，kata-clh 表现优于 kata-qemu。

## 6. 推荐 Pod Overhead 配置

### 嵌套虚拟化

```yaml
# kata-clh — 嵌套虚拟化
overhead:
  podFixed:
    cpu: 100m
    memory: 200Mi   # 当前值已经最优，达到了调度器上限
```

当前 200 MiB 的 overhead 已经验证足够，不需要增加。

### 裸金属

```yaml
# kata-clh — 裸金属
overhead:
  podFixed:
    cpu: 100m
    memory: 170Mi   # 实测 167 MiB + ~2% 余量
```

## 7. 文件

| 文件 | 说明 |
|------|------|
| `max-pod-test-fullload-v2.sh` | 测试脚本（支持运行时参数） |
| `results-fullload-clh.csv` | 逐 Pod 原始指标（CSV 格式） |
| `test-fullload-clh.log` | 完整测试执行日志 |
| `README.md` | 本分析文档 |
