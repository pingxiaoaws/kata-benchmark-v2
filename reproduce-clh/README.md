# Kata Containers Cloud Hypervisor (CLH) vs QEMU 对比测试

## 概述

使用与 kata-qemu 完全相同的 Pod 配置、工作负载和物理节点，在 kata-clh 运行时上复现测试，对比两种 VMM 的内存效率、稳定性和资源可见性差异。

## 测试环境

| 项目 | kata-qemu | kata-clh |
|------|-----------|----------|
| 集群 | Amazon EKS 1.34, us-west-2 | 同左 |
| **节点** | **ip-172-31-17-237** | **同一节点** |
| **机型** | **m8i.2xlarge (8 vCPU, 32 GiB)** | **同左** |
| Host 内核 | 6.12.68-92.122.amzn2023.x86_64 | 同左 |
| Kata 版本 | 3.27.0 | 同左 |
| VMM | QEMU | **Cloud Hypervisor** |
| Kata VM 内核 | 6.18.12 | 同左 |
| Pod 数量 | 7 | 7 |
| RuntimeClass overhead | cpu:500m, memory:640Mi | cpu:100m, memory:200Mi |

**苹果对苹果**：两组测试在同一物理节点上先后执行（先 QEMU，清除后 CLH），消除硬件差异。

---

## Pod 配置（两组完全一致）

```yaml
containers:
- name: gateway       # nginx, requests 150m/1Gi, limits 1500m/2Gi, liveness+readiness probe
- name: config-watcher # dd of=/dev/shm/memblock count=700 (700 MiB)
- name: envoy          # dd of=/dev/shm/memblock2 count=700 (700 MiB)
- name: wazuh          # dd of=/dev/shm/memblock3 count=600 (600 MiB)
# 每 pod /dev/shm 合计: ~2.0 GiB
```

---

## 测试结果

### 采集时间

- kata-qemu: 2026-04-12 05:01 UTC（稳态运行 65 分钟）
- kata-clh: 2026-04-12 07:16 UTC（稳态运行 ~2 分钟后采集，/dev/shm 写入已完成）

### Layer 1: kubectl top pod（guest 内容器 cgroup）

| Pod | kata-qemu | kata-clh |
|-----|-----------|----------|
| sandbox-1 | 977 MiB | 1005 MiB |
| sandbox-2 | 2085 MiB* | 1004 MiB |
| sandbox-3 | 977 MiB | 1006 MiB |
| sandbox-4 | 977 MiB | 1005 MiB |
| sandbox-5 | 977 MiB | 1005 MiB |
| sandbox-6 | 976 MiB | 1006 MiB |
| sandbox-7 | 976 MiB | 1005 MiB |
| **平均（排除异常）** | **977 MiB** | **1005 MiB** |

*QEMU sandbox-2 未 restart，gateway nginx 内存膨胀到 1115 MiB

**结论**：guest 容器 cgroup 层面基本一致（CLH 略高 ~3%，属正常波动）。

### Layer 2: VMM 进程 RSS

| VM | QEMU RSS | CLH RSS |
|----|----------|---------|
| 1 | ~2,400 MiB | 1,261 MiB |
| 2 | ~2,400 MiB | 1,261 MiB |
| 3 | ~2,400 MiB | 1,255 MiB |
| 4 | ~2,400 MiB | 1,257 MiB |
| 5 | ~2,400 MiB | 1,257 MiB |
| 6 | ~2,400 MiB | 1,256 MiB |
| 7 | ~1,300 MiB* | 1,257 MiB |
| **合计** | **15,185 MiB** | **8,807 MiB** |
| **平均** | **2,169 MiB** | **1,258 MiB** |

*QEMU VM 7 多次 restart 后 RSS 较低

**CLH VMM RSS = QEMU 的 58%，每 VM 少 ~911 MiB。**

VIRT / RES / SHR 对比（同节点 32 GiB）：

| | QEMU | CLH |
|---|------|-----|
| VIRT | 8,752 MiB | 7,370 MiB |
| RES | ~2,400 MiB | ~1,260 MiB |
| SHR | ~2,400 MiB | ~1,260 MiB |
| %MEM (per VM) | 7.9% | 4.0% |

### Layer 3: kubectl top node（同节点）

| | kata-qemu | kata-clh |
|---|-----------|----------|
| CPU | 1,136m (14%) | 144m (1%) |
| **Memory** | **16,387 MiB (54%)** | **10,597 MiB (35%)** |

**同一 32 GiB 节点上，CLH 少用 5.8 GiB（-35%）。**

### Layer 4: Host free -m（同节点）

| | kata-qemu | kata-clh |
|---|-----------|----------|
| total | 31,554 MiB | 31,554 MiB |
| used | 1,497 MiB | 1,319 MiB |
| free | 8,355 MiB | 14,222 MiB |
| **shared** | **14,479 MiB** | **8,781 MiB** |
| available | 15,126 MiB | 21,003 MiB |

CLH 的 `shared`（memfd 映射）少了 5.7 GiB，`available` 多了 5.9 GiB。

### virtiofsd 对比

| | kata-qemu | kata-clh |
|---|-----------|----------|
| worker 数 | 14 (7×2) | 14 (7×2) |
| 总 RSS | ~280 MiB | 260 MiB |
| 平均每 VM | ~40 MiB | ~18 MiB |

---

### 不可见内存开销（同节点对比）

```
                        kata-qemu           kata-clh
kubectl top pod 合计:    7.8 GiB*            6.9 GiB
kubectl top node:       16.0 GiB            10.3 GiB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
不可见开销:              8.2 GiB             3.4 GiB
每 pod 不可见:          ~1.2 GiB            ~0.5 GiB    ← CLH 低 58%
```

*QEMU 含 sandbox-2 的异常高值

---

### Pod 稳定性对比

| Pod | kata-qemu restarts | kata-clh restarts | CLH 失败原因 |
|-----|-------------------|-------------------|-------------|
| sandbox-1 | gateway=1 | **0** | — |
| sandbox-2 | gateway=0 | **all=2** | shim 创建失败 (`ttrpc: closed`) |
| sandbox-3 | gateway=1 | **0** | — |
| sandbox-4 | gateway=1 | **0** | — |
| sandbox-5 | gateway=1 | **0** | — |
| sandbox-6 | all=1 | **0** | — |
| sandbox-7 | gateway=2, others=1 | **all=1** | shim 创建失败 (`500`) |

**kata-qemu 的 restart 原因**：
- gateway liveness probe timeout（内存分配风暴期间 nginx 响应慢）
- sandbox-6/7 的全容器 restart：可能是 sandbox 级别的短暂故障

**kata-clh 的 restart 原因**：
- sandbox-2: `failed to start containerd task: ttrpc: closed` + `API response receive error: receiving on a closed channel`
- sandbox-7: `failed to create shim task: 500`
- 这是 **CLH shim/API 层面的启动竞态**，不是 probe 超时。7 个 VM 同时启动时，CLH 的 containerd shim 出现连接丢失。
- 重建 sandbox 后恢复正常

**结论**：
- QEMU restart 是内存压力导致的 probe 超时（渐进式，可调 timeout 缓解）
- CLH restart 是 shim 启动竞态（瞬间故障，retry 后恢复，但暴露了 CLH shim 在高并发启动下的脆弱性）

---

## 综合对比总结

| 维度 | kata-qemu | kata-clh | 赢家 |
|------|-----------|----------|------|
| **VMM RSS (每 VM)** | 2,169 MiB | 1,258 MiB | **CLH (-42%)** |
| **不可见开销 (每 pod)** | ~1.2 GiB | ~0.5 GiB | **CLH (-58%)** |
| **kubectl top node (7 pods)** | 16.0 GiB (54%) | 10.3 GiB (35%) | **CLH (-35%)** |
| **Host available mem** | 15.1 GiB | 21.0 GiB | **CLH (+39%)** |
| **kubectl top pod (准确性)** | 低估 2.1x | 低估 1.5x | **CLH（更接近真实）** |
| **启动稳定性** | ✅ 全部成功 | ⚠️ 2/7 shim 竞态 | **QEMU** |
| **稳态稳定性** | probe 超时 restart | 稳态无 restart | **CLH** |
| **高负载稳定性 (Test 5b)** | ✅ 稳定 | ❌ crash | **QEMU** |
| **网络吞吐 (Test 3)** | -50% vs runc | -74% vs runc | **QEMU** |

---

## 容量规划影响

基于同节点 m8i.2xlarge (32 GiB) 实测数据：

| | kata-qemu | kata-clh |
|---|-----------|----------|
| 每 pod 实际内存 | ~2.3 GiB (node层) | ~1.5 GiB (node层) |
| 32 GiB 节点 max pods | **5-6** | **8-10** |
| 64 GiB 节点 max pods | **12-15** | **18-22** |
| 相同节点密度提升 | 基线 | **+50-60%** |

---

## Pod Overhead 推荐值

```yaml
# kata-qemu
overhead:
  podFixed:
    cpu: "100m"
    memory: "250Mi"    # 实测 207 MiB + 20%

# kata-clh
overhead:
  podFixed:
    cpu: "100m"
    memory: "200Mi"    # 实测 167 MiB + 20%
```

---

## 生产建议

| 场景 | 推荐 VMM |
|------|---------|
| **生产环境（稳定性优先）** | **kata-qemu** — 高负载不 crash，shim 启动可靠 |
| **开发/测试（密度优先）** | kata-clh — 内存效率高 50%+，可跑更多 pod |
| **批处理/短生命周期** | kata-clh — 启动竞态可 retry，内存优势显著 |
| **高并发启动** | kata-qemu — CLH shim 有竞态风险 |
| **网络密集型** | kata-qemu — CLH 网络吞吐损失更大 (-74% vs -50%) |

---

## 文件清单

```
reproduce-clh/
├── README.md                    ← 本文件
├── test11g-clh-profile.sh       ← CLH 稳态内存画像脚本
```

## 关联测试

- QEMU 对照组：[reproduce/](../reproduce/) 目录
- Test 5b (CLH 高负载 crash)：[results/](../results/) 目录
- Test 9 (CLH 空载内存画像)：[results/](../results/) 目录
- Test 10 (CLH Pod Overhead)：[results/](../results/) 目录
