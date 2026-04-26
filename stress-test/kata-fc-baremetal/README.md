# kata-fc Max Pod Density Test — m7g.metal (Bare Metal)

## Overview

Test the maximum number of kata-fc (Firecracker) pods deployable on a single Graviton3 bare metal instance.

## Environment

| Component | Detail |
|-----------|--------|
| Instance | m7g.metal |
| Architecture | aarch64 (Graviton3) |
| vCPU | 64 |
| Memory | 256 GiB |
| Allocatable | 63.77 CPU, ~243 GiB, 250 pods |
| Host Kernel | 6.12.79-101.147.amzn2023.aarch64 |
| Kata VM Kernel | 6.18.12 |
| K8s | EKS 1.34 |
| RuntimeClass | kata-fc (Firecracker) |

## Pod Overhead (RuntimeClass)

```yaml
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
```

## Test Configuration

- Pod resource request: `memory: 64Mi, cpu: 10m`
- Effective per-pod (with overhead): `memory: 194Mi, cpu: 260m`
- Sleep command: `sleep 86400` (idle workload)
- Deployment: batches of 10 pods, wait for Running between batches

## Results

### Summary

| Metric | Value |
|--------|-------|
| **Max Running Pods** | **240** |
| Pending (Unschedulable) | 10 |
| Failed | 0 |
| **Bottleneck** | **CPU scheduling** |
| Time to deploy 240 pods | ~11 min |

### Node Resource at Max

| Resource | Requests | % |
|----------|----------|---|
| CPU | 63,590m | **99%** |
| Memory | 47,734Mi | **19%** |

### Scheduling Failure Reason

```
Insufficient cpu
0/3 nodes are available: 1 Insufficient cpu, 
1 node(s) didn't match Pod's node affinity/selector, 
1 node(s) had untolerated taint(s).
```

### Theoretical Analysis

| Constraint | Calculation | Max Pods |
|------------|-------------|----------|
| CPU scheduling | 63,770m / 260m | ~245 |
| Memory scheduling | 248,847Mi / 194Mi | ~1,283 |
| EKS max-pods | hard limit | 250 |
| **Actual result** | (daemonsets use ~180m CPU) | **240** |

## Key Findings

1. **CPU overhead is the density limiter** — 250m overhead per pod means each Firecracker VM consumes 260m of schedulable CPU even when idle
2. **Memory is NOT the bottleneck** — only 19% utilized at max density
3. **Zero failures at 240 pods** — Firecracker is stable on Graviton3 bare metal
4. **~30 sec per batch of 10** — Firecracker boot time is fast on bare metal (no nested virt overhead)

## Optimization Opportunities

- **Reduce CPU overhead to 100m** (matching kata-qemu): would allow ~250 pods (EKS limit)
- **Increase EKS max-pods**: default 250 is close to the limit anyway
- **Use larger instance**: m7g.metal is already the biggest Graviton3

## Files

- `run-maxpods-test.sh` — Test script
- `v2-test-fc-maxpods.csv` — Per-batch snapshot data
- `v2-test-fc-maxpods-stdout.log` — Full test log
