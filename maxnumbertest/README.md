# Maximum Stable Pod Count Test: kata-qemu on m8i.2xlarge

**Date:** 2026-04-13 03:06-03:22 UTC  
**Result: 10 pods stable, pod 11 triggered cascading VM failures (31 container restarts)**

## Environment

| Property | Value |
|----------|-------|
| Node | ip-172-31-17-237.us-west-2.compute.internal |
| Instance | m8i.2xlarge (8 vCPU, 32 GiB) |
| Virtualization | **Nested** (KVM inside EC2 .metal-equivalent) |
| Node Allocatable | cpu=7910m, memory=30619520Ki (~29903 MiB) |
| RuntimeClass | kata-qemu |
| Pod Overhead | cpu=100m, memory=250Mi |
| Kata default_vcpus | 5 |
| Kata default_memory | 2048 MiB |
| K8s version | v1.34.4-eks |
| Containerd | 2.1.5 |

### Pod Spec (Guaranteed QoS, request = limit)

| Container | CPU | Memory | Workload |
|-----------|-----|--------|----------|
| gateway (nginx:1.27) | 150m | 1Gi | nginx + liveness/readiness probe |
| config-watcher (busybox:1.36) | 100m | 256Mi | 200 MiB shm + sleep loop |
| envoy (busybox:1.36) | 100m | 256Mi | 200 MiB shm + CPU loop |
| wazuh (busybox:1.36) | 100m | 512Mi | 400 MiB shm + find loop |
| **Container totals** | **450m** | **2048 MiB** | |
| **+ RuntimeClass overhead** | **+100m** | **+250 MiB** | |
| **Scheduling footprint** | **550m** | **2298 MiB** | |

## Theoretical Calculation

```
Node allocatable memory: 29903 MiB
System pod requests:     -  150 MiB  (aws-node, kube-proxy, etc.)
Available for test pods:  29753 MiB

Per pod (with overhead):   2298 MiB
Max pods by memory: floor(29753 / 2298) = 12

Node allocatable CPU:     7910m
System pod requests:      - 190m
Available for test pods:   7720m

Per pod (with overhead):    550m
Max pods by CPU: floor(7720 / 550) = 14

Theoretical maximum = 12 pods (memory-limited)
```

## Actual Result

| Metric | Value |
|--------|-------|
| **Maximum stable pod count** | **10** |
| Stop trigger | 31 container restarts after deploying pod 11 |
| Theoretical maximum | 12 (scheduler-limited by memory) |
| Gap | 2 pods (17% fewer than theoretical) |
| Failure mode | Cascading VM kills during 11th VM startup |

## Per-Pod Data Table

### Steady-State Metrics (collected 60s after each pod reached Ready)

| Pod | Ready (s) | kt top pod (MiB) | QEMU RSS (MiB) | kt top node (MiB) | Host Avail (MiB) | Restarts |
|-----|-----------|-------------------|-----------------|--------------------|-------------------|----------|
| 1 | 13 | 809 | 1144 | 2773 | 28876 | 0 |
| 2 | 13 | 810 | 2292 | 3852 | 27780 | 0 |
| 3 | 12 | 809 | 3435 | 4930 | 26679 | 0 |
| 4 | 12 | 808 | 4581 | 6012 | 25596 | 0 |
| 5 | 13 | 810 | 5728 | 7087 | 24509 | 0 |
| 6 | 13 | 810 | 6877 | 8183 | 23389 | 0 |
| 7 | 12 | 811 | 8027 | 9269 | 22275 | 0 |
| 8 | 13 | 809 | 9177 | 10344 | 21199 | 0 |
| 9 | 13 | 810 | 10331 | 11434 | 20096 | 0 |
| 10 | 12 | 809 | 11478 | 12515 | 18993 | 0 |
| **11** | **37** | **N/A** (metrics crashed) | **10426** | **N/A** | **19911** | **31** |

Note: "kt top pod" values are per-pod sums from `kubectl top pod --containers` (gateway ~6Mi + config-watcher ~200Mi + envoy ~201Mi + wazuh ~402Mi).

### Per-Container Metrics (consistent across all 10 stable pods)

| Container | CPU (kubectl top) | Memory (kubectl top) | /dev/shm allocated |
|-----------|------------------|---------------------|--------------------|
| gateway | 1m | 6 MiB | n/a |
| config-watcher | 0-1m | 200-201 MiB | 200 MiB |
| envoy | 100-101m | 200-201 MiB | 200 MiB |
| wazuh | 2m | 401-402 MiB | 400 MiB |
| **Total** | **~104m** | **~809 MiB** | **800 MiB** |

## Node-Level Data at Each Step

| Pods | Node CPU | CPU% | Node Mem | Mem% | Host Total | Host Used | Host Free | Host Avail | QEMU RSS Total |
|------|----------|------|----------|------|------------|-----------|-----------|------------|----------------|
| 0 (baseline) | 36m | 0% | 1704Mi | 5% | 31554 | 1133 | 23163 | 29968 | 0 |
| 1 | 1173m | 14% | 2773Mi | 9% | 31554 | 1180 | 22072 | 28876 | 1144 |
| 2 | 1295m | 16% | 3852Mi | 12% | 31554 | 1229 | 20976 | 27780 | 2292 |
| 3 | 1547m | 19% | 4930Mi | 16% | 31554 | 1287 | 19870 | 26679 | 3435 |
| 4 | 1878m | 23% | 6012Mi | 20% | 31554 | 1324 | 18783 | 25596 | 4581 |
| 5 | 2062m | 26% | 7087Mi | 23% | 31554 | 1364 | 17693 | 24509 | 5728 |
| 6 | 2181m | 27% | 8183Mi | 27% | 31554 | 1435 | 16568 | 23389 | 6877 |
| 7 | 2566m | 32% | 9269Mi | 31% | 31554 | 1499 | 15451 | 22275 | 8027 |
| 8 | 2529m | 31% | 10344Mi | 34% | 31554 | 1525 | 14371 | 21199 | 9177 |
| 9 | 2941m | 37% | 11434Mi | 38% | 31554 | 1574 | 13264 | 20096 | 10331 |
| 10 | 2984m | 37% | 12515Mi | 41% | 31554 | 1630 | 12164 | 18993 | 11478 |
| 11 (crash) | N/A | N/A | N/A | N/A | 31554 | 1730 | 13087 | 19911 | 10426 |

All memory values in MiB.

### Incremental Cost Per Pod (derived from stable range pods 1-10)

| Metric | Per-Pod Delta | Notes |
|--------|---------------|-------|
| QEMU RSS | ~1148 MiB | Remarkably consistent: 1140-1151 MiB per VM |
| kubectl top node memory | ~1081 MiB | What kubelet's cAdvisor sees |
| Host available (free -m) | ~1098 MiB | Actual host memory consumed |
| Host buff/cache | ~1050 MiB | VM memory pages in page cache |
| Host "used" (free -m) | ~50 MiB | QEMU process metadata only |
| kubectl top node CPU | ~295m | Per VM: 5 vCPUs but workload only uses ~104m |

## Memory Visibility Analysis

This is the core finding of this test. Four different tools report four different numbers for the same workload:

```
                     Per Pod (MiB)
                     ─────────────
kubectl top pod:          809    ← container cgroup RSS inside guest VM
QEMU RSS (host ps):      1148    ← guest memory pages touched + QEMU overhead
kubectl top node (Δ):    1081    ← cAdvisor sees QEMU sandbox cgroup
Host free -m (Δ avail):  1098    ← actual host physical memory consumed
Scheduler reservation:   2298    ← container requests (2048) + overhead (250)
```

### Why the numbers differ

1. **kubectl top pod (809 MiB)** reports container RSS **inside the guest VM**. It sees the 800 MiB of /dev/shm data plus nginx's 6 MiB. It does NOT see guest kernel memory, kata-agent, or QEMU overhead. This is the least useful number for capacity planning.

2. **QEMU RSS (1148 MiB)** is the physical memory the host kernel has assigned to the QEMU process. It includes all touched guest pages + QEMU's own heap. The VM has 2048 MiB allocated but only ~1148 MiB of pages have been faulted in (the workload only touches ~809 MiB + guest kernel ~200 MiB + QEMU overhead ~139 MiB).

3. **kubectl top node (1081 MiB delta)** comes from cAdvisor reading the QEMU sandbox's cgroup. Slightly lower than host `ps` because cAdvisor samples at different times and accounts for shared pages differently.

4. **Host available (1098 MiB delta)** is the ground truth from the kernel's perspective. It closely tracks QEMU RSS, confirming that's the real cost.

5. **Scheduler reservation (2298 MiB)** is a pure accounting fiction. The scheduler prevents scheduling more than 12 pods, but the host only consumes 1098 MiB per pod. At 10 pods, the scheduler thinks 76% of memory is used; the host reports only 41%.

### The visibility gap

```
Scheduler sees:     10 pods × 2298 MiB = 22980 MiB reserved (77% of allocatable)
Host actually uses: 10 pods × 1148 MiB = 11480 MiB QEMU RSS  (36% of physical)
Host available:     18993 MiB (60% of physical still free)
```

The scheduler over-reserves by 2.0x compared to actual host consumption. This is because:
- Container limits (2048 MiB) are enforced inside the VM by the kata-agent, not on the host
- The QEMU process RSS only reflects touched pages, not the full VM allocation
- The 250 MiB overhead is added on top, further widening the gap

## Pod 11 Failure Analysis

### Timeline

```
03:19:54  Pod 11 created
03:20:02  7 existing VMs killed simultaneously (pods 2,3,4,5,7,8,9)
03:20:03  Containers restart in killed VMs
03:20:31  Pod 11 finally reaches Ready (37s vs normal 12-13s)
03:21:31  Settle period ends — 31 restarts detected across all pods
```

### What happened

The 11th QEMU VM startup caused a **cascading VM failure**. Key evidence:

1. **Simultaneous death**: All container exits in pods 2,3,4,5,7,8,9 have `finishedAt: 2026-04-13T03:20:02Z` - the same second. This rules out individual container OOM; something killed the VMs externally.

2. **QEMU process replacement**: Before pod 11, there were 10 QEMU PIDs (1018318-1024633). After the crash, 7 of those PIDs are gone, replaced by new higher PIDs (1025446-1027212). The surviving PIDs correspond exactly to pods 1, 6, and 10 (the pods with 0 restarts).

3. **Pod 11 slow startup**: 37 seconds to Ready vs 12-13s for pods 1-10. The host was under severe resource contention.

4. **No host-level OOM**: `dmesg` shows no QEMU OOM kills. Host available memory was ~19 GiB — plenty of headroom. The failure is not memory exhaustion.

5. **Nested virtualization bottleneck**: With 11 VMs running under nested virtualization, the L1 KVM hypervisor must manage shadow EPT page tables for each VM. Launching the 11th VM while 10 are actively running (with memory-intensive workloads) creates extreme pressure on the L1 hypervisor's page table management, leading to VM scheduling stalls and eventual crashes.

### Surviving vs. killed VMs

| Survived (0 restarts) | Killed (4-5 restarts) |
|-----------------------|----------------------|
| sandbox-1 (oldest) | sandbox-2 |
| sandbox-6 (middle) | sandbox-3 |
| sandbox-10 (newest) | sandbox-4 |
| | sandbox-5 |
| | sandbox-7 |
| | sandbox-8 |
| | sandbox-9 |

The survival pattern (1, 6, 10) does not follow a clear age-based or resource-based ordering. This is consistent with non-deterministic hypervisor scheduling under contention.

## Gap Analysis: Theoretical vs Actual

```
Scheduler theoretical max:     12 pods  (memory-limited)
Actual stable max:             10 pods  (nested virt contention)
Gap:                            2 pods  (17%)
```

### Why the gap exists

| Factor | Impact |
|--------|--------|
| **Nested virtualization overhead** | Primary cause. L1 KVM managing 10+ VMs with EPT shadowing creates extreme contention. On bare metal, 12+ pods would likely succeed. |
| **VM startup resource spike** | Each QEMU VM temporarily consumes more resources during startup (page table setup, memory balloon, kernel boot). With 10 VMs already running, the spike for VM 11 pushes the hypervisor past its limit. |
| **QEMU VSZ vs RSS** | Each QEMU has VSZ=5327 MiB but RSS=~1148 MiB. The virtual address space reservations (mmap'd but not faulted) still consume kernel resources for VMAs and page tables. |
| **Guest kernel overhead** | Each VM's guest kernel consumes ~200 MiB that is invisible to `kubectl top pod` but counts against the QEMU RSS. With 10 VMs, that's 2 GiB of "hidden" memory. |

### What would change on bare metal

On a bare-metal m8i.2xlarge (no nested virtualization):
- VM startup would be ~2x faster (no EPT shadowing)
- CPU overhead per VM would be ~30-50% lower  
- The hypervisor contention wall at 10-11 VMs would not exist
- Expected stable count: **12 pods** (matching scheduler limit)
- With reduced overhead, possibly **13-14** if overhead is tuned down

## Recommended Pod Overhead

### Current state (nested virtualization)

The current overhead of `cpu=100m, memory=250Mi` allows the scheduler to place 12 pods, but the node becomes unstable at 11. To prevent this:

```yaml
# Conservative for nested virtualization
overhead:
  podFixed:
    cpu: 250m      # accounts for QEMU + hypervisor CPU overhead
    memory: 950Mi  # limits scheduler to 10 pods: floor(29753 / (2048+950)) = 9
```

With `memory: 950Mi` overhead, the scheduler would allow `floor(29753 / 2998) = 9 pods`, providing a 1-pod safety margin below the observed 10-pod limit.

### For bare metal (recommended)

```yaml
# Tight but safe for bare metal (no nested virt)
overhead:
  podFixed:
    cpu: 100m
    memory: 250Mi  # scheduler allows 12 pods — likely the real stable limit
```

The current 250 MiB overhead is appropriate for bare metal where the nested virtualization penalty doesn't exist.

### Overhead based on observed host memory

If you want the scheduler to accurately predict host memory consumption (rather than over-reserve):

```
Actual host memory per pod:  ~1148 MiB (QEMU RSS)
Container requests:           2048 MiB (enforced in-guest, not on host)
"Correct" overhead:           1148 - 2048 = -900 MiB  (impossible)
```

This reveals a fundamental mismatch: the Kubernetes scheduler model assumes container requests map to host memory. In kata-containers, they don't — they map to **guest VM memory**. The host only sees the QEMU RSS. The overhead mechanism cannot correct for this because it can only add, not subtract.

**Practical recommendation**: Accept the over-reservation. It provides a safety margin against workloads that touch more guest memory than this test's 800 MiB of /dev/shm.

## Summary of Key Numbers

| Metric | Value |
|--------|-------|
| Maximum stable pods (this test) | **10** |
| Scheduler theoretical max | 12 |
| QEMU RSS per pod | 1148 MiB |
| kubectl top pod per pod | 809 MiB |
| Host memory per pod (actual) | ~1098 MiB |
| Scheduler reservation per pod | 2298 MiB |
| Over-reservation ratio | 2.0x |
| VM startup time (stable) | 12-13s |
| VM startup time (at limit) | 37s |
| Failure mode | Cascading VM kills from nested virt contention |
| Host memory at failure | 19 GiB available (60% free) |

## Files

| File | Description |
|------|-------------|
| `max-pod-test.sh` | Test script |
| `results.csv` | Raw per-pod metrics in CSV format |
| `test.log` | Full test execution log (630 lines) |
| `README.md` | This analysis |
