# Max Pod Density Test: kata-clh Full Stress on m8i.4xlarge (Nested Virtualization)

**Date:** 2026-04-14 03:33–04:21 UTC  
**Result: 24 pods stable under full CPU+memory stress (node at 90% memory), test completed normally**

## 1. Environment

| Property | Value |
|----------|-------|
| Node | ip-172-31-18-59.us-west-2.compute.internal |
| Instance Type | **m8i.4xlarge** (16 vCPU, 64 GiB) |
| Virtualization | **Nested** (KVM inside EC2 bare-metal-equivalent) |
| Node Allocatable | cpu=15890m, memory=58567 MiB |
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
| **Scheduler sees per pod** | **550m** | **2248 MiB** | |

## 3. Results Summary

| Metric | Value |
|--------|-------|
| Max stable pods | **24** |
| Final node CPU request | 9907m (62%) |
| Final node memory request | 52983 MiB (90%) |
| Total restarts | 0 |
| All pods OK | ✅ |
| Test duration | ~47 minutes |

## 4. Key Observations

- kata-clh achieved **24 pods** on m8i.4xlarge under full stress, vs kata-qemu's **14 pods** (pod 15 had restarts)
- CLH's lower Pod Overhead (200Mi vs 250Mi) allows higher density
- At 24 pods the node was at 90% memory — approaching the limit
- No crashes or restarts observed during the entire test run

## 5. Cross-comparison with Other Tests

| Test | Runtime | Instance | Max Stable Pods | Limiting Factor |
|------|---------|----------|-----------------|-----------------|
| stress-4x-qemu | kata-qemu | m8i.4xlarge | 14 | Pod 15 restarts |
| **stress-4x-clh** | **kata-clh** | **m8i.4xlarge** | **24** | **90% memory** |
| stress-2x-qemu | kata-qemu | m8i.2xlarge | 6 | Pod 7 OOM |
| stress-2x-clh | kata-clh | m8i.2xlarge | 13 | Pod 14 Failed |
