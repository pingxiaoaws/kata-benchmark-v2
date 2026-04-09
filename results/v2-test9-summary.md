# Test 9: kata-clh Memory Footprint Profiling

**Date:** 2026-04-09  
**Node:** ip-172-31-19-254.us-west-2.compute.internal (m8i.4xlarge, 64 GiB RAM, 16 vCPU)  
**Total Node Memory:** 63,257 MiB  
**Runtimes:** runc (baseline) vs kata-clh (cloud-hypervisor)  
**Base Image:** registry.k8s.io/pause:3.10

---

## 9A: Single Pod Idle Memory Delta

Measures MemAvailable drop from deploying a single idle pause container.

| Runtime        | Round 1 | Round 2 | Round 3 | **Mean Delta (MiB)** |
|----------------|---------|---------|---------|----------------------|
| **runc**       | 12      | 10      | 0       | **7.3**              |
| **kata-clh**   | 165     | 169     | 167     | **167.0**            |

**Overhead:** kata-clh consumes ~**167 MiB** per idle pod vs ~**7 MiB** for runc.  
**Delta:** ~**160 MiB** additional memory per kata-clh VM for an idle pause container.

> **vs kata-qemu (Test 7):** kata-qemu used ~204 MiB per idle pod. kata-clh is ~37 MiB lighter (~18% reduction), reflecting cloud-hypervisor's leaner footprint compared to QEMU.

---

## 9B: cloud-hypervisor Process RSS

Direct measurement of the cloud-hypervisor process memory via `/proc/<pid>/status` and `/proc/<pid>/smaps_rollup`.

Note: pgrep found 3 PIDs per round (1 main process + 2 child threads/processes). Only the main process had measurable RSS; child PIDs returned empty values.

| Metric       | Round 1    | Round 2    | Round 3    | **Mean**       |
|-------------|------------|------------|------------|----------------|
| VmRSS       | 153,080 kB | 153,712 kB | 153,412 kB | **153,401 kB** (~150 MiB) |
| VmHWM       | 153,080 kB | 153,712 kB | 153,412 kB | **153,401 kB** (~150 MiB) |
| PSS (smaps) | 151,944 kB | 152,578 kB | 152,394 kB | **152,305 kB** (~149 MiB) |
| RssAnon     | 1,320 kB   | 1,320 kB   | 1,316 kB   | **1,319 kB**   (~1.3 MiB) |
| RssFile     | 3,804 kB   | 3,804 kB   | 3,804 kB   | **3,804 kB**   (~3.7 MiB) |
| RssShmem    | 147,960 kB | 148,592 kB | 148,292 kB | **148,281 kB** (~145 MiB) |

### RSS Breakdown:
- **RssAnon (1.3 MiB):** cloud-hypervisor heap, vCPU state — dramatically lower than QEMU's 16 MiB
- **RssFile (3.7 MiB):** cloud-hypervisor binary + shared libraries — vs QEMU's 84 MiB
- **RssShmem (145 MiB):** Guest RAM backed by shared memory — vs QEMU's 168 MiB
- **Total RSS: ~150 MiB**, PSS: ~149 MiB (almost no sharing with other processes)

> **vs kata-qemu (Test 7):** QEMU RSS was ~269 MiB. cloud-hypervisor is ~119 MiB lighter (~44% reduction). The biggest savings come from RssFile (84 -> 3.7 MiB, cloud-hypervisor is a single static binary) and RssAnon (16 -> 1.3 MiB, minimal device emulation overhead).

---

## 9C: Cgroup Memory Accounting

| Runtime        | Cgroup memory.current |
|----------------|----------------------|
| **runc**       | 495,616 bytes (0.47 MiB) |
| **kata-clh**   | 0 bytes               |

**Key Finding:** Identical to kata-qemu — the pod-level cgroup reports **0 bytes** for kata-clh. The cloud-hypervisor process manages its own memory outside the container's cgroup accounting. This means:

1. `kubectl top pod` **cannot see** the VM overhead (~150 MiB RSS)
2. Kubernetes resource accounting is **blind** to the actual host memory consumed by kata VMs
3. This cgroup blindness is a property of the **kata runtime architecture**, not the specific VMM

---

## 9D: Memory Overhead Under Stress

Measures host MemAvailable delta with stress-ng allocating increasing memory inside the pod.

| Stress (MiB) | runc Delta | kata-clh Delta | **Overhead (kata-clh - runc)** |
|-------------|------------|----------------|-------------------------------|
| 0           | 10         | 202            | **192**                       |
| 256         | 281        | 453            | **172**                       |
| 512         | 533        | 724            | **191**                       |
| 1024        | 1,043      | 1,265          | **222**                       |

**Mean overhead: ~194 MiB** (std dev: ~20 MiB)

### Analysis:
- The overhead is essentially **constant** (~172-222 MiB) regardless of application memory pressure
- For runc, host delta tracks the stress allocation nearly 1:1 (as expected)
- For kata-clh, host delta = stress allocation + fixed VM overhead
- The fixed overhead does not grow proportionally with application memory — it's a **flat tax**

> **vs kata-qemu (Test 7):** kata-qemu mean overhead was ~228 MiB. kata-clh is ~34 MiB lighter (~15% reduction).

---

## 9E: Multi-Pod Linearity

Deploys 1/2/4/8 pause pods and measures total and per-pod memory overhead.

| # Pods | Runtime    | Total Delta (MiB) | Per-Pod Delta (MiB) |
|--------|-----------|-------------------|---------------------|
| 1      | runc       | 9                 | 9.0                 |
| 1      | kata-clh   | 175               | **175.0**           |
| 2      | runc       | 2                 | 1.0                 |
| 2      | kata-clh   | 341               | **170.5**           |
| 4      | runc       | 15                | 3.7                 |
| 4      | kata-clh   | 678               | **169.5**           |
| 8      | runc       | 74                | 9.2                 |
| 8      | kata-clh   | 1,335             | **166.8**           |

### Analysis:
- **kata-clh scales linearly:** 8 pods = 1,335 MiB ~ 8 x 167 MiB
- **Per-pod overhead is constant** at ~167-175 MiB (no sharing between VMs)
- **runc overhead is negligible:** 8 pods = 74 MiB total (~9 MiB per pod)
- **No memory deduplication** between kata-clh VMs (each VM is fully independent)

> **vs kata-qemu (Test 7):** kata-qemu per-pod was ~207-213 MiB. kata-clh is ~40 MiB lighter per pod. At 8 pods: kata-qemu = 1,659 MiB vs kata-clh = 1,335 MiB (324 MiB saved).

### Capacity Implication:
On this 64 GiB node, maximum kata-clh pods (idle) ~ (64,000 - 2,000 system) / 170 ~ **~365 pods** (memory-bound)  
vs kata-qemu: ~299 pods — kata-clh supports ~22% more pods per node.

---

## Summary Table: kata-clh vs kata-qemu vs runc

| Metric | runc | kata-clh | kata-qemu (Test 7) | CLH Savings |
|--------|------|----------|---------------------|-------------|
| Idle pod memory delta | ~7 MiB | ~167 MiB | ~204 MiB | **37 MiB (18%)** |
| VMM process RSS | N/A | ~150 MiB | ~269 MiB | **119 MiB (44%)** |
| VMM process PSS | N/A | ~149 MiB | ~268 MiB | **119 MiB (44%)** |
| RssAnon (heap) | N/A | ~1.3 MiB | ~16 MiB | **14.7 MiB (92%)** |
| RssFile (binary+libs) | N/A | ~3.7 MiB | ~84 MiB | **80.3 MiB (96%)** |
| RssShmem (guest RAM) | N/A | ~145 MiB | ~168 MiB | **23 MiB (14%)** |
| Cgroup visibility | Yes (0.47 MiB) | **No** (0 bytes) | **No** (0 bytes) | Same blind spot |
| Overhead under stress (mean) | N/A | ~194 MiB | ~228 MiB | **34 MiB (15%)** |
| Per-pod overhead (multi-pod) | ~6 MiB | ~170 MiB | ~209 MiB | **39 MiB (19%)** |
| Linearity | Sublinear | **Linear** | **Linear** | Both linear |

## Key Takeaways

1. **cloud-hypervisor is significantly lighter than QEMU.** Each kata-clh pod costs ~167-175 MiB vs kata-qemu's ~200-210 MiB — a consistent ~18-20% memory savings per pod.

2. **The biggest savings come from the VMM binary itself.** cloud-hypervisor's RssFile is 3.7 MiB vs QEMU's 84 MiB (96% reduction), reflecting its single static binary architecture vs QEMU's extensive shared library dependencies. RssAnon (heap) drops from 16 MiB to 1.3 MiB (92% reduction) due to minimal device emulation.

3. **Guest RAM (RssShmem) savings are modest.** 145 MiB vs 168 MiB (~14% reduction), suggesting both VMMs allocate similar amounts for the default 128 MiB guest, with minor differences in firmware/kernel overhead.

4. **The cgroup blind spot is identical.** Both kata-clh and kata-qemu report 0 bytes in cgroup memory.current. This is a kata architecture issue, not VMM-specific. `kubectl top` remains useless for kata pod memory accounting.

5. **kata-clh scales linearly with no memory sharing between VMs**, same as kata-qemu. Per-pod overhead stays constant at ~170 MiB whether running 1 or 8 pods.

6. **Capacity benefit:** On a 64 GiB node, kata-clh supports ~22% more pods than kata-qemu (365 vs 299 estimated max idle pods).

---

*Results files:*
- `v2-test9a-idle-memory-delta.csv`
- `v2-test9b-clh-rss.csv`
- `v2-test9c-cgroup-vs-top.csv`
- `v2-test9d-stress-overhead.csv`
- `v2-test9e-multi-pod-linearity.csv`
