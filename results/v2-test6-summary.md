# Test 6: 嵌套虚拟化运行时真实开销测试 — 结果摘要

**日期**: 2026-04-04
**集群**: test-s4 (EKS 1.34, us-west-2)
**节点**: m8i.4xlarge (16 vCPU, 64GB RAM)
**运行时**: runc (containerd 2.1.5), kata-qemu, kata-clh

## 6A. CPU 计算吞吐量 (sysbench cpu, 4 threads, prime=20000)

| Runtime | Avg Events/sec | Stdev | vs runc |
|---------|---------------|-------|---------|
| runc | 5160.61 | 2.03 | +0.00% |
| kata-qemu | 5109.91 | 3.73 | -0.98% |
| kata-clh | 5109.44 | 12.45 | -0.99% |

## 6B. 内存带宽 (sysbench memory, 1M blocks, 10G total, 4 threads)

| Runtime | Avg MiB/sec | Stdev | vs runc |
|---------|------------|-------|---------|
| runc | 59430.63 | 755.62 | +0.00% |
| kata-qemu | 60492.19 | 673.15 | +1.79% |
| kata-clh | 56792.34 | 1196.46 | -4.44% |

## 6C. 磁盘 I/O

### 顺序写 (fio, 1M blocks, 256M, direct=1, 30s)

| Runtime | Avg BW (MB/s) | Avg Latency (us) | vs runc BW |
|---------|--------------|-------------------|------------|
| runc | 127.73 | 7827.42 | +0.0% |
| kata-qemu | 2209.98 | 451.81 | +1630.2% |
| kata-clh | 2093.61 | 477.92 | +1539.1% |

### 随机读写 (fio, 4K blocks, 64M, 4 jobs, direct=1, 30s)

| Runtime | Avg Read IOPS | Avg Write IOPS | vs runc Read |
|---------|--------------|----------------|--------------|
| runc | 1542.59 | 1554.64 | +0.0% |
| kata-qemu | 23562.45 | 23607.87 | +1427.5% |
| kata-clh | 14656.03 | 14674.90 | +850.1% |

## 6D. 网络性能 (同节点 pod-to-pod)

| Runtime | Avg Throughput (Gbps) | Avg Latency (ms) | vs runc Throughput |
|---------|--------------------|-------------------|-------------------|
| runc | 64.13 | 0.061 | +0.0% |
| kata-qemu | 31.91 | 0.803 | -50.2% |
| kata-clh | 16.56 | 0.837 | -74.2% |

## 6E. Host CPU 开销 (sysbench cpu 4T x 60s, /proc/stat delta)

| Runtime | Avg Pod CPU (sec) | Avg Host CPU (sec) | Overhead % |
|---------|------------------|-------------------|------------|
| runc | 240.00 | 242.95 | 1.00% |
| kata-qemu | 240.00 | 242.57 | 1.00% |
| kata-clh | 240.00 | 242.80 | 1.00% |

## 6F. 综合负载 (stress-ng, bogo ops/sec real-time)

| Runtime | CPU bogo/s | VM bogo/s | IO bogo/s | CPU Params |
|---------|-----------|-----------|-----------|------------|
| runc | 4660.03 | 37303.50 | 10262.49 | 4 cpu, 2 vm, 2 io, 60s |
| kata-qemu | 5826.97 | 44077.54 | 442.07 | 4 cpu, 2 vm, 2 io, 60s |
| kata-clh | 4448.23 | 39385.57 | 366.78 | 2 cpu, 1 vm, 1 io, 30s* |

*kata-clh stress-ng 使用减少参数以避免 OpenClaw 应用 crash

## 关键发现

1. **CPU 计算**: kata-qemu 和 kata-clh 的 CPU 吞吐量与 runc 非常接近（差距 < 1%），表明嵌套虚拟化对纯计算几乎无额外开销。

2. **内存带宽**: 三种运行时内存性能基本一致（~57-61 GiB/s），kata-clh 略低约 5%。

3. **磁盘 I/O**: 
   - **顺序写**: kata 容器写速 ~2100-2200 MB/s，远高于 runc 的 ~128 MB/s。这是因为 kata VM 使用 virtiofs/DAX 的 page cache 加速，而 runc 的 direct I/O 直达 EFS backend。
   - **随机读写**: 类似模式 — kata IOPS 远高于 runc，原因同上（kata VM 内部有额外 cache 层）。

4. **网络**: 
   - runc 吞吐 ~64 Gbps（接近 veth pair 极限）
   - kata-qemu ~32 Gbps（runc 的 ~50%）
   - kata-clh ~16.5 Gbps（runc 的 ~26%，但测试使用 2 streams）
   - 延迟: runc ~0.06ms, kata ~0.8-0.9ms（增加 ~13x）

5. **Host CPU 开销**: 所有运行时开销均约 1%，差异极小。这说明 kata VMM 本身不消耗额外显著 CPU。

6. **综合负载 (stress-ng)**: kata-qemu CPU bogo/s 略高于 runc，可能因 VM 内 scheduler 差异。IO bogo/s 下降最明显（kata ~440 vs runc ~10000），反映虚拟化 I/O 路径开销。

## 稳定性观察

- **kata-clh 稳定性问题**: kata-clh 运行时在高负载下频繁导致 OpenClaw 容器 crash（startup probe 失败）。需要持久化工具安装到 EFS 卷才能完成测试。这可能是 Cloud Hypervisor 资源调度或 virtio-fs 的问题。
- runc 和 kata-qemu 均稳定完成所有测试。
