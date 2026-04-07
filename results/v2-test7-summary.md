# Test 7: Runtime Memory Footprint Profiling

**Date:** 2026-04-07  
**Node:** node-2 (m8i.4xlarge, 64 GiB RAM, 16 vCPU)  
**Kernel:** 6.12.68-92.122.amzn2023.x86_64  
**Total Node Memory:** 63,257 MiB  
**Runtimes:** runc (default containerd) vs kata-qemu  
**Base Image:** registry.k8s.io/pause:3.10

---

## 7A: Single Pod Idle Memory Delta

Measures MemAvailable drop from deploying a single idle pause container.

| Runtime    | Round 1 | Round 2 | Round 3 | **Mean Delta (MiB)** |
|------------|---------|---------|---------|----------------------|
| **runc**       | -2      | 6       | 9       | **4.3**              |
| **kata-qemu**  | 199     | 206     | 206     | **203.7**            |

**Overhead:** kata-qemu consumes ~**204 MiB** per idle pod vs ~**4 MiB** for runc.  
**Delta:** ~**200 MiB** additional memory per kata-qemu VM for an idle pause container.

> The runc numbers are near-zero (within noise), confirming the pause container itself uses negligible memory. The ~200 MiB overhead is entirely attributable to the QEMU VM + guest kernel + virtio devices.

---

## 7B: QEMU Process RSS

Direct measurement of the qemu-system process memory via `/proc/<pid>/status` and `/proc/<pid>/smaps_rollup`.

| Metric       | Round 1    | Round 2    | Round 3    | **Mean**       |
|-------------|------------|------------|------------|----------------|
| VmRSS       | 275,204 kB | 275,196 kB | 275,052 kB | **275,151 kB** (~269 MiB) |
| VmHWM       | 275,204 kB | 275,200 kB | 275,052 kB | **275,152 kB** (~269 MiB) |
| PSS (smaps) | 274,064 kB | 274,080 kB | 273,900 kB | **274,015 kB** (~268 MiB) |
| RssAnon     | 16,788 kB  | 16,872 kB  | 16,804 kB  | **16,821 kB**  (~16 MiB)  |
| RssFile     | 85,900 kB  | 85,900 kB  | 85,900 kB  | **85,900 kB**  (~84 MiB)  |
| RssShmem    | 172,544 kB | 172,428 kB | 172,352 kB | **172,441 kB** (~168 MiB) |

### RSS Breakdown:
- **RssAnon (16 MiB):** QEMU heap, device emulation state, vCPU thread stacks
- **RssFile (84 MiB):** QEMU binary + shared libraries mapped from disk
- **RssShmem (168 MiB):** Guest RAM backed by shared memory (the VM's actual memory)
- **Total RSS: ~269 MiB**, PSS: ~268 MiB (almost no sharing with other processes)

> Note: VmRSS ≈ VmHWM means QEMU's peak memory equals its steady-state — no transient allocation spikes.

---

## 7C: Cgroup Memory Accounting

| Runtime    | Cgroup memory.current |
|------------|----------------------|
| **runc**       | 491,520 bytes (0.47 MiB) |
| **kata-qemu**  | 0 bytes               |

**Key Finding:** For kata-qemu, the pod-level cgroup reports **0 bytes** because the QEMU process manages its own memory outside the container's cgroup accounting. This means:

1. `kubectl top pod` **cannot see** the VM overhead (~269 MiB RSS)
2. Kubernetes resource accounting is **blind** to the actual host memory consumed by kata VMs
3. Capacity planning based on `kubectl top` will **underestimate** kata-qemu memory usage by ~269 MiB per pod

---

## 7D: Memory Overhead Under Stress

Measures host MemAvailable delta with stress-ng allocating increasing memory inside the pod.

| Stress (MiB) | runc Delta | kata-qemu Delta | **Overhead (kata - runc)** |
|-------------|------------|-----------------|---------------------------|
| 0           | 7          | 238             | **231**                    |
| 256         | 287        | 487             | **200**                    |
| 512         | 532        | 756             | **224**                    |
| 1024        | 1,038      | 1,293           | **255**                    |

**Mean overhead: ~228 MiB** (std dev: ~23 MiB)

### Analysis:
- The overhead is essentially **constant** (~200-255 MiB) regardless of application memory pressure
- For runc, host delta tracks the stress allocation nearly 1:1 (as expected)
- For kata-qemu, host delta = stress allocation + fixed VM overhead
- The fixed overhead does not grow proportionally with application memory — it's a **flat tax**

---

## 7E: Multi-Pod Linearity

Deploys 1/2/4/8 pause pods and measures total and per-pod memory overhead.

| # Pods | Runtime    | Total Delta (MiB) | Per-Pod Delta (MiB) |
|--------|-----------|-------------------|---------------------|
| 1      | runc       | 15                | 15.0                |
| 1      | kata-qemu  | 208               | **208.0**           |
| 2      | runc       | 14                | 7.0                 |
| 2      | kata-qemu  | 425               | **212.5**           |
| 4      | runc       | 14                | 3.5                 |
| 4      | kata-qemu  | 841               | **210.2**           |
| 8      | runc       | 57                | 7.1                 |
| 8      | kata-qemu  | 1,659             | **207.3**           |

### Analysis:
- **kata-qemu scales linearly:** 8 pods = 1,659 MiB ≈ 8 x 207 MiB
- **Per-pod overhead is constant** at ~207-213 MiB (no sharing between VMs)
- **runc overhead is negligible:** 8 pods = 57 MiB total (~7 MiB per pod, mostly kernel metadata)
- **No memory deduplication** between kata-qemu VMs (each VM has its own kernel, QEMU instance)

### Capacity Implication:
On this 64 GiB node, maximum kata-qemu pods (idle) ≈ (64,000 - 2,000 system) / 207 ≈ **~299 pods** (memory-bound)  
vs runc: memory is essentially not the limiting factor for idle pods.

---

## Summary Table

| Metric | runc | kata-qemu | Overhead |
|--------|------|-----------|----------|
| Idle pod memory delta | ~4 MiB | ~204 MiB | **~200 MiB** |
| QEMU process RSS | N/A | ~269 MiB | — |
| QEMU process PSS | N/A | ~268 MiB | — |
| Cgroup visibility | Yes (0.47 MiB) | **No** (0 bytes) | kubectl top blind |
| Overhead scaling with app memory | N/A | Constant (~228 MiB) | Flat tax |
| Per-pod overhead (multi-pod) | ~7 MiB | ~209 MiB | **~202 MiB** |
| Linearity | Sublinear | **Linear** | No VM sharing |

## Key Takeaways

1. **Each kata-qemu pod costs ~200-210 MiB of host memory** just for the VM overhead (QEMU + guest kernel), regardless of workload size.

2. **This overhead is invisible to Kubernetes.** `kubectl top` and cgroup accounting report 0 for kata pods. Operators must use host-level tooling (`/proc/<pid>/status`, `free -m`) for accurate capacity planning.

3. **The overhead is a fixed cost per VM**, not proportional to application memory. A pod using 256 MiB or 1 GiB of application memory has the same ~200-250 MiB VM overhead.

4. **No memory sharing between VMs.** Per-pod overhead stays constant at ~207-213 MiB whether you run 1 or 8 pods. Each VM is fully independent.

5. **QEMU RSS breakdown:** 16 MiB heap + 84 MiB mapped files + 168 MiB shared memory (guest RAM) = 269 MiB total.

---

*Results files:*
- `v2-test7a-idle-memory-delta.csv`
- `v2-test7b-qemu-rss.csv`
- `v2-test7c-cgroup-vs-top.csv`
- `v2-test7d-stress-overhead.csv`
- `v2-test7e-multi-pod-linearity.csv`
