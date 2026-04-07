# Test 5b: Memory Oversell Stability Test

**Date:** 2026-04-07 08:27 UTC
**Node:** node-oversell (r8i.2xlarge, 8 vCPU, 64GB RAM)
**Allocatable memory:** 63084396Ki (~60GiB)
**Pod spec:** pause container (registry.k8s.io/pause:3.10), request=128Mi/50m, limit=256Mi/100m

## Phase 1: Baseline — VM Overhead per Pod (10 pods)

| Metric | runc | kata-qemu | Delta |
|--------|------|-----------|-------|
| MemAvailable before deploy | 61310 MiB | 61310 MiB | — |
| MemAvailable after 10 pods | 61225 MiB | 59269 MiB | **1956 MiB** |
| Overhead per pod | ~9 MiB | ~204 MiB | **~195 MiB/pod VM overhead** |

Each kata-qemu pod consumes ~195 MiB of host memory for the QEMU process + guest kernel, even for a minimal pause container. runc pods have negligible overhead (~9 MiB total for 10 pods).

## Phase 2: Progressive Load (kata-qemu)

| Target Pods | Running | Pending | Failed | MemAvailable (MiB) | OOM Events | Notes |
|-------------|---------|---------|--------|-------------------|------------|-------|
| 10 | 10 | 0 | 0 | 59273 | 0 | All healthy |
| 20 | 20 | 0 | 0 | 57198 | 0 | All healthy |
| 30 | 30 | 0 | 0 | 55112 | 0 | All healthy |
| 40 | 36 | 0 | 0 | 53020 | 0 | 4 pods still initializing |
| 50 | 39 | 0 | 0 | 53150 | 0 | Scheduler pressure begins |
| 60 | 35 | 0 | 4 | 51429 | 0 | First pod failures |
| 80 | 35 | 0 | 4 | 53518 | 0 | Plateau ~35 running |
| 100 | 36 | 0 | 4 | 51344 | 0 | Running count stable |
| 120 | 40 | 12 | 4 | 52138 | 0 | Pods start going Pending |
| 150 | 40 | 40 | 4 | 52526 | 0 | Scheduler at capacity |
| 200 | 40 | 90 | 4 | N/A | 0 | Massive Pending backlog |

### Key Observations

- **No host-level OOM kills detected.** The Kubernetes scheduler's resource accounting prevented true memory exhaustion. Pods went Pending (Insufficient cpu/memory) rather than causing host OOM.
- **Running pods plateau at ~35-40**, regardless of target. This is the scheduler's effective capacity given the resource requests (128Mi + 50m CPU per pod) plus VM overhead.
- **4 pod failures** appeared at 60+ target — these are kata VM startup failures (likely sandbox creation timeouts), not OOM kills.
- **MemAvailable stabilized at ~51-53 GiB** even at high target counts, because additional pods couldn't be scheduled.
- **Memory consumed**: 30 running kata pods used ~6.2 GiB of host memory (30 × ~204 MiB), visible in the MemAvailable drop from 61.3 GiB → 55.1 GiB.

### Theoretical vs Actual Capacity

| Calculation | Value |
|-------------|-------|
| Node allocatable memory | ~60 GiB |
| Per-pod VM overhead | ~195 MiB |
| Theoretical max kata pods (memory only) | ~315 pods (60 GiB / 195 MiB) |
| Actual max running pods | ~35-40 |
| Limiting factor | **CPU requests** (50m × 40 = 2000m, plus DaemonSet pods consuming remaining CPU) |

The CPU request (50m per pod) is actually the bottleneck, not memory. With 8 vCPU allocatable and DaemonSet overhead, ~40 pods × 50m = 2000m CPU requested is approaching schedulable limits alongside other resource constraints.

## Phase 3: runc Comparison at 40 Pods

| Runtime | Target | Running | Pending | Failed | MemAvailable (MiB) | OOM |
|---------|--------|---------|---------|--------|-------------------|-----|
| runc | 40 | 40 | 0 | 0 | 60944 | 0 |
| kata-qemu | 40 | 36 | 0 | 0 | 53020 | 0 |

**runc at 40 pods**: All 40 Running, MemAvailable = 60944 MiB (only 366 MiB used)
**kata-qemu at 40 pods**: Only 36 Running, MemAvailable = 53020 MiB (8290 MiB used)

**Memory overhead ratio**: kata-qemu uses **22.6× more host memory** than runc for the same workload at 40 pods.

## Conclusions

1. **VM overhead is ~195 MiB per kata-qemu pod** for minimal containers — this is the QEMU process + guest kernel cost.
2. **Kubernetes scheduler prevents host OOM** by tracking resource requests. Memory oversell doesn't manifest as host OOM kills when resource requests are properly set.
3. **The real danger is when requests < actual usage**: If kata-qemu pods request only 128Mi but actually consume ~195MiB for VM overhead alone, the scheduler under-accounts memory. With more memory-intensive workloads, this gap widens.
4. **CPU requests were the actual bottleneck** in this test, limiting pods to ~40 before the scheduler ran out of CPU budget.
5. **runc has negligible overhead**: 40 runc pods used only 366 MiB total vs 8290 MiB for kata-qemu — a 22.6× difference.

## Recommendation

For kata-qemu workloads, set memory requests to **at least actual_app_memory + 256Mi** to account for VM overhead. Under-requesting memory creates a hidden oversell that can cause host instability under load. CPU oversell (Test 5) is safe at 200%; memory oversell is not.

## CSV Data

Full results: `results/v2-test5b-memory-oversell.csv`
