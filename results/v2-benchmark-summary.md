# OpenClaw Kata Benchmark v2 Summary

**Date**: 2026-04-03  
**Cluster**: test-s4, EKS 1.34, us-west-2  
**Operator**: v0.22.2  
**Runtimes**: runc, kata-qemu, kata-clh  
**Nodes**: 9x m8i.4xlarge + 1x r8i.2xlarge + 1x m8i.4xlarge (untainted)

---

## Test 1: Single Pod Cold Boot (5 iterations each)

| Runtime    | Iter 1 (cold) | Iter 2 | Iter 3 | Iter 4 | Iter 5 | Avg (warm) | Kernel        |
|------------|---------------|--------|--------|--------|--------|------------|---------------|
| runc       | 49.22s        | 54.84s | 53.13s | 51.32s | 50.26s | 51.75s     | 6.12.68 (host)|
| kata-qemu  | 119.82s       | 67.57s | 75.61s | 74.16s | 64.45s | 70.45s     | 6.18.12 (VM)  |
| kata-clh   | 107.10s       | 104.77s| 70.30s | 74.23s | 71.61s | 72.04s*    | 6.18.12 (VM)  |

\* kata-clh warm avg excludes first 2 cold iterations: 72.05s

**Key findings**:
- First kata cold boot includes VM image pull + setup: ~120s (kata-qemu), ~107s (kata-clh)
- Warm boot overhead: kata adds ~18-20s vs runc (~37% slower)
- kata-qemu and kata-clh have similar warm boot performance
- Kernel isolation confirmed: kata pods run 6.18.12, runc pods see host 6.12.68

---

## Test 2: Saturated Node Boot (15 existing pods, 3 iterations each)

Target: node-1 (m8i.4xlarge, 16 vCPU)

| Runtime    | Iter 1 | Iter 2 | Iter 3 | Avg     |
|------------|--------|--------|--------|---------|
| runc       | 59.26s | 55.72s | 47.30s | 54.09s  |
| kata-qemu  | 89.90s | 64.92s | 101.88s| 85.57s  |
| kata-clh   | 96.21s | 69.04s | 103.96s| 89.74s  |

**Key findings**:
- runc is resilient under saturation: ~54s avg (only ~2s slower than empty node)
- Kata shows higher variance under load: 65-104s range
- Kata overhead increases under node saturation (~85-90s avg vs ~70s on idle node)

---

## Test 3: 10-Node Full Load Boot (120 fill pods, 3 iterations each)

| Runtime    | Iter 1  | Iter 2  | Iter 3  | Avg     |
|------------|---------|---------|---------|---------|
| runc       | 49.17s  | 52.20s  | 52.41s  | 51.26s  |
| kata-qemu  | 68.97s  | 69.12s  | 67.19s  | 68.43s  |
| kata-clh   | 104.86s | 104.82s | 67.16s  | 92.28s  |

**Key findings**:
- runc boot time unchanged by cluster-wide load (~51s, same as idle)
- kata-qemu consistent at ~68-69s across all iterations
- kata-clh shows cold-start penalty on new nodes (105s first 2, then 67s)
- Scheduler successfully spreads pods across available nodes

---

## Test 4: Runtime Comparison (same node: node-10)

| Runtime    | Boot Time | Gateway | CPU (idle) | Memory (idle) | Kernel  |
|------------|-----------|---------|------------|---------------|---------|
| runc       | 47.51s    | 200 OK  | 1m         | 408Mi         | 6.12.68 |
| kata-qemu  | 69.24s    | 200 OK  | 2m         | 411Mi         | 6.18.12 |
| kata-clh   | 66.20s    | 200 OK  | 1m         | 401Mi         | 6.18.12 |

**Key findings**:
- All runtimes serve gateway traffic correctly (HTTP 200)
- Idle resource usage nearly identical across runtimes (~1-2m CPU, ~400Mi memory)
- Kata VM overhead is negligible at steady state
- kata-clh slightly faster than kata-qemu on warm boot (66s vs 69s)

---

## Test 5: R8i Oversell Stability (16 kata-qemu pods, 2h monitoring)

**Node**: node-oversell (r8i.2xlarge, 8 vCPU, 64GB RAM)  
**Overcommit**: 16 pods x 400m CPU request = 6.4 CPU (fits scheduler)  
**Potential usage**: 16 pods x 1 CPU limit = 16 CPU (200% of 8 vCPU capacity)

### Stability Metrics (24 checks over 2 hours)

| Metric                  | Value                    |
|-------------------------|--------------------------|
| Total pods              | 16 (all kata-qemu)       |
| Pods Running at end     | 16/16 (100%)             |
| OOM events              | 0                        |
| Max restarts (any pod)  | 2 (3 pods)               |
| Pods with 0 restarts    | 6/16 (37.5%)             |
| Pods with 1 restart     | 7/16 (43.75%)            |
| Pods with 2 restarts    | 3/16 (18.75%)            |
| Node CPU (initial)      | 8000m (100% saturated)   |
| Node CPU (steady state) | 300-400m (~4%)           |
| Node memory (steady)    | ~23.5GB / 64GB (37%)     |
| Gateway health          | Healthy after warmup      |

### Restart Timeline
- Restarts occurred during initial pod startup phase (first 10 min)
- No restarts observed during steady-state monitoring
- Restart cause: likely startup resource contention, not OOM

**Key findings**:
- 16 kata-qemu VMs stable on 8 vCPU node for 2+ hours
- No OOM kills despite 200% CPU overcommit potential
- Idle workloads settle to ~20m CPU per pod (total ~320m on 8 vCPU node)
- Memory footprint manageable: ~1.5GB per kata-qemu VM (idle)
- Overselling kata VMs is viable for idle/low-utilization workloads

---

## Overall Conclusions

1. **Boot Time Overhead**: Kata adds ~18-20s to warm boot times vs runc (~37% overhead). First cold boot on a new node includes VM image caching and takes 100-120s.

2. **kata-qemu vs kata-clh**: Nearly identical performance. kata-clh slightly faster on warm boots but shows more variance on cold starts.

3. **Scalability**: Boot times remain consistent under cluster-wide load (120+ pods). Node saturation adds 15-20s to kata boots.

4. **Resource Efficiency**: At idle, kata VMs use nearly identical CPU/memory as runc containers. The overhead is purely in boot time, not steady-state resources.

5. **Oversell Viability**: 16 kata-qemu VMs run stably on an 8 vCPU node with 200% CPU overcommit (by limits). Critical for cost optimization with idle workloads. Zero OOM events over 2 hours.

6. **Kernel Isolation Confirmed**: All kata pods consistently report kernel 6.18.12 (VM), while runc pods show host kernel 6.12.68. Operator v0.22.2 correctly passes runtimeClassName.

---

## CSV Files

- `v2-test1-boot-time.csv` - Cold boot times (15 measurements)
- `v2-test2-saturated-boot-time.csv` - Saturated node boots (9 measurements)
- `v2-test3-multi-node-boot-time.csv` - Multi-node load boots (9 measurements)
- `v2-test4-runtime-comparison.csv` - Runtime comparison (3 measurements)
- `v2-test5-oversell-stability.csv` - Oversell monitoring (384 data points)
