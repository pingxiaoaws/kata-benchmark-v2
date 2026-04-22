# CubeSandbox 性能测试计划

> 目标：在 EC2 bare-metal 上独立验证 CubeSandbox 的冷启动、内存开销、网络性能和部署密度  
> 对比基线：Docker 容器 + Kata-QEMU/CLH（复用已有 benchmark 数据）

## 0. 前提条件

### 平台限制
- CubeSandbox **仅支持 x86_64 + KVM**，不支持 ARM (aarch64)
- 需要 **bare-metal EC2**（/dev/kvm 直通）
- 推荐实例：`m7i.metal-24xl` 或 `c7i.metal-24xl`（96 vCPU, 192/384 GiB）

### 为什么不能用 m8g
- m8g 是 Graviton (ARM) 实例
- CubeSandbox 的 CubeHypervisor 和 release tarball 均为 x86_64 二进制
- RustVMM 底层依赖 x86 KVM 特定接口（如 kvm_ioctls 的 x86 模块）

## 1. 测试矩阵

| Test ID | 测试项 | 方法 | 对比基线 |
|---------|--------|------|---------|
| CS-1 | 冷启动延迟 | E2B SDK 创建沙箱，计时 | Kata-QEMU/CLH pod 创建时间 |
| CS-2 | 并发冷启动 | 1/10/50/100/200 并发创建 | N/A |
| CS-3 | 内存开销 | 空沙箱 MemAvailable delta | Kata 207/167 MiB |
| CS-4 | 部署密度 | 逐步增加沙箱至 OOM | Kata ~300 pods/node |
| CS-5 | 网络吞吐 | iperf3 沙箱内→外部 | Kata 32/16 Gbps |
| CS-6 | 网络延迟 | ping RTT | Kata ~0.13ms |
| CS-7 | CPU 计算 | sysbench CPU 沙箱内 | runc/Kata < 1% 差异 |
| CS-8 | 代码执行 E2E | Python 计算任务 E2E 延迟 | Docker 容器 |

## 2. 环境准备

### 2.1 申请 EC2 bare-metal

```bash
# 推荐 m7i.metal-24xl (us-west-2)
aws ec2 run-instances \
  --instance-type m7i.metal-24xl \
  --image-id ami-xxxxxxxx \
  --key-name kata-benchmark \
  --security-group-ids sg-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cubesandbox-benchmark}]'
```

### 2.2 安装 CubeSandbox

```bash
# 验证 KVM
ls -la /dev/kvm

# 安装依赖
yum install -y docker qemu-kvm git python3 python3-pip
systemctl start docker

# 部署 CubeSandbox
curl -sL https://github.com/tencentcloud/CubeSandbox/raw/master/deploy/one-click/online-install.sh | bash

# 创建模板
cubemastercli tpl create-from-image \
  --image ccr.ccs.tencentyun.com/ags-image/sandbox-code:latest \
  --writable-layer-size 1G \
  --expose-port 49999 \
  --expose-port 49983 \
  --probe 49999
```

## 3. 测试脚本

### CS-1: 冷启动延迟

```python
#!/usr/bin/env python3
"""CS-1: CubeSandbox 冷启动延迟测试"""
import os, time, json, statistics

TEMPLATE_ID = os.environ["CUBE_TEMPLATE_ID"]
ITERATIONS = 50

results = []
for i in range(ITERATIONS):
    start = time.perf_counter()
    from e2b_code_interpreter import Sandbox
    with Sandbox.create(template=TEMPLATE_ID) as sandbox:
        ready = time.perf_counter()
        # 验证沙箱可用
        result = sandbox.run_code("print('ok')")
    end = time.perf_counter()
    
    create_ms = (ready - start) * 1000
    e2e_ms = (end - start) * 1000
    results.append({"iter": i+1, "create_ms": create_ms, "e2e_ms": e2e_ms})
    print(f"[{i+1}/{ITERATIONS}] create={create_ms:.1f}ms e2e={e2e_ms:.1f}ms")

create_times = [r["create_ms"] for r in results]
print(f"\n=== Cold Start Summary ===")
print(f"Mean:   {statistics.mean(create_times):.1f} ms")
print(f"Median: {statistics.median(create_times):.1f} ms")
print(f"P95:    {sorted(create_times)[int(len(create_times)*0.95)]:.1f} ms")
print(f"P99:    {sorted(create_times)[int(len(create_times)*0.99)]:.1f} ms")
print(f"Min:    {min(create_times):.1f} ms")
print(f"Max:    {max(create_times):.1f} ms")

with open("results/cs1-cold-start.json", "w") as f:
    json.dump(results, f, indent=2)
```

### CS-3: 内存开销

```bash
#!/bin/bash
# CS-3: 内存开销测试 - 逐步创建沙箱，测量 MemAvailable delta
set -euo pipefail

echo "=== CS-3: Memory Overhead ==="

# 基线
BASELINE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
echo "Baseline MemAvailable: ${BASELINE} kB"

for COUNT in 1 10 50 100 200 500; do
    # 创建 $COUNT 个沙箱 (需要通过 API)
    echo "Creating ${COUNT} sandboxes..."
    
    AFTER=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    DELTA_KB=$((BASELINE - AFTER))
    PER_SANDBOX_KB=$((DELTA_KB / COUNT))
    PER_SANDBOX_MB=$((PER_SANDBOX_KB / 1024))
    
    echo "${COUNT} sandboxes: delta=${DELTA_KB}kB, per_sandbox=${PER_SANDBOX_MB}MiB"
    
    # 清理
    echo "Cleaning up..."
done
```

## 4. 预期结果与分析方向

| 指标 | CubeSandbox 官方声称 | Kata-QEMU 实测 | 测试要点 |
|------|---------------------|---------------|---------|
| 冷启动 | < 60ms | ~300ms | 是否需要资源池预热？预热后的测量 vs 冷池 |
| 内存 | < 5 MiB | 207 MiB | CoW 增量 vs 全量分配，实际峰值内存 |
| 网络 | 未声称 | 32 Gbps | eBPF 路径 vs tc-redirect-tap |
| 密度 | "单机数千" | ~300 pods | 观察 OOM killer 触发点 |

### 关键验证问题

1. **5 MiB 内存开销是否真实？** 这可能是 CoW 增量页计算，实际物理内存占用需看 `MemAvailable` delta
2. **60ms 冷启动是否包含资源池预热？** 如果池中无预热 VM，实际冷启动可能数秒
3. **eBPF 网络 vs Kata tc-redirect-tap**：CubeVS 跳过了 bridge/iptables，理论上延迟更低
4. **CPU 开销**：同为 KVM MicroVM + EPT，计算密集型任务应与 Kata 一致

## 5. 输出物

- `results/cs1-cold-start.json` - 冷启动延迟原始数据
- `results/cs2-concurrent-start.json` - 并发启动数据
- `results/cs3-memory-overhead.json` - 内存开销数据
- `results/cs4-density.json` - 部署密度数据
- `results/cs5-network-throughput.json` - 网络吞吐数据
- `results/cubesandbox-benchmark-report.md` - 综合报告

---

*计划创建时间：2026-04-22*
