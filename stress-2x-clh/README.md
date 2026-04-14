# Max Pod Density Test: kata-clh Full Stress on m8i.2xlarge (Nested Virtualization)

**Date:** 2026-04-14 02:45–03:10 UTC  
**Result: 13 pods stable under full CPU+memory stress (scheduler limit reached), pod 14 Failed**

## 1. Environment

| Property | Value |
|----------|-------|
| Node | ip-172-31-30-148.us-west-2.compute.internal |
| Instance Type | **m8i.2xlarge** (8 vCPU, 32 GiB) |
| Virtualization | **Nested** (KVM inside EC2 bare-metal-equivalent) |
| Node Allocatable | cpu=7910m, memory=29901 MiB |
| RuntimeClass | **kata-clh** |
| Pod Overhead | cpu=100m, memory=200Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s version | v1.34.4-eks |
| Stress tool | polinux/stress-ng (CPU 95% load + vm-keep) |

## 2. Pod Specification (Guaranteed QoS, request = limit)

| Container | CPU | Memory | stress-ng Args |
|-----------|-----|--------|----------------|
| gateway | 150m | 1 GiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 900M --vm-keep` |
| config-watcher | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| envoy | 100m | 256 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 200M --vm-keep` |
| wazuh | 100m | 512 MiB | `--cpu 1 --cpu-load 95 --vm 1 --vm-bytes 450M --vm-keep` |
| **Container totals** | **450m** | **2048 MiB** | |
| **+ RuntimeClass overhead** | **+100m** | **+200 MiB** | |
| **Scheduling footprint** | **550m** | **2248 MiB** | |

## 3. Theoretical Maximum

```
Node allocatable memory: 29901 MiB
System pod requests:     -  150 MiB
Available for test pods:  29751 MiB

Per pod (with overhead):   2248 MiB
Max pods by memory: floor(29751 / 2248) = 13

Node allocatable CPU:     7910m
System pod requests:      - 190m
Available for test pods:   7720m

Per pod (with overhead):    550m
Max pods by CPU: floor(7720 / 550) = 14

Theoretical maximum = 13 pods (memory-limited)
```

## 4. Results

### Per-Pod Metrics

| Pod | Ready(s) | Node CPU | CPU% | Node Mem | Mem% | stress CPU | stress Mem (MiB) | Status |
|-----|----------|----------|------|----------|------|------------|------------------|--------|
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

### Incremental Cost Per Pod

| Metric | Per-Pod Delta | Notes |
|--------|---------------|-------|
| kubectl top node memory | ~2130 MiB | cAdvisor: QEMU sandbox cgroup |
| kubectl top node CPU | ~384m | 5 vCPUs, stress driving ~452m |
| stress-ng CPU per pod | ~452m | Consistent across all 13 pods |
| stress-ng memory per pod | ~1807 MiB | Remarkably consistent |
| VM startup time | 7s | No degradation even at 13 pods |

### Summary

| Metric | Value |
|--------|-------|
| **Maximum stable pods** | **13** |
| Scheduler theoretical max | 13 (memory-limited) |
| Gap | **0 pods (100% of scheduler limit!)** |
| Failure trigger | Pod 14 — scheduler rejected (insufficient memory) |
| Node CPU at 13 pods | 66% |
| Node memory at 13 pods | 95% |
| Total restarts (all pods) | 0 |

## 5. Analysis

### 5.1 kata-clh 达到了调度器上限

这是所有测试中唯一一次 **100% 达到调度器理论上限** 的结果。13 个 pod 全部稳定，0 restart，pod 14 因为调度器内存不足被拒绝（不是 VM crash）。

### 5.2 与 kata-qemu 同机型对比 (m8i.2xlarge)

| 维度 | kata-qemu | kata-clh | 差异 |
|------|-----------|----------|------|
| 稳定 pods | 7 | **13** | **+86%** |
| 理论上限 | 12 | 13 | +8% (overhead 更小) |
| 利用率 vs 理论 | 58% | **100%** | +42pp |
| 失败时 node mem% | 53% | 95% | 更高利用 |
| 失败时 node CPU% | 36% | 66% | 更高利用 |
| 失败模式 | VM crash (4 restarts) | 调度器拒绝 | 更优雅 |
| 每 pod cAdvisor 内存 Δ | ~2161 MiB | ~2130 MiB | CLH 略小 |
| VM startup time | 6-7s | 7s | 相当 |

### 5.3 Why kata-clh Performs Better

1. **Cloud Hypervisor 更轻量**：CLH 进程本身 RSS 比 QEMU 小 ~40 MiB（Test 9 数据：167 MiB vs 207 MiB）
2. **更好的嵌套虚拟化兼容性**：CLH 使用更简单的设备模型，EPT 影子页表管理压力更小
3. **内存效率更高**：Pod overhead 只有 200 MiB（vs QEMU 250 MiB），每 pod 节省 50 MiB
4. **无级联 crash**：即使到 13 pods（95% 内存），所有 VM 仍然稳定运行

### 5.4 Previously Known kata-clh Weakness

之前 Test 5b 和 Test 10 发现 kata-clh 在高负载下会 crash。但那些测试是**超卖场景**（memory overcommit），而本测试是 Guaranteed QoS（request = limit）。在不超卖的情况下，kata-clh 表现优于 kata-qemu。

## 6. Recommended Pod Overhead for kata-clh

### Nested Virtualization

```yaml
# kata-clh — Nested Virtualization
overhead:
  podFixed:
    cpu: 100m
    memory: 200Mi   # 当前值已经最优，达到了调度器上限
```

当前 200 MiB 的 overhead 已经验证足够，不需要增加。

### Bare Metal

```yaml
# kata-clh — Bare Metal
overhead:
  podFixed:
    cpu: 100m
    memory: 170Mi   # 实测 167 MiB + ~2% margin
```

## 7. Files

| File | Description |
|------|-------------|
| `max-pod-test-fullload-v2.sh` | Test script (supports runtime parameter) |
| `results-fullload-clh.csv` | Raw per-pod metrics in CSV format |
| `test-fullload-clh.log` | Full test execution log |
| `README.md` | This analysis |
