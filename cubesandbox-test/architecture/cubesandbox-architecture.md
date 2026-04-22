# CubeSandbox 架构分析

> 源码：https://github.com/TencentCloud/CubeSandbox  
> 版本：v0.1.0 (2026-04-20 首次开源)  
> 许可：Apache 2.0  

## 1. 项目定位

CubeSandbox 是腾讯云开源的 **AI Agent 安全沙箱服务**，面向 AI 代码执行场景（Code Interpreter、SWE-Bench RL 训练等）。核心卖点：

| 指标 | Docker 容器 | 传统 VM | CubeSandbox |
|------|------------|---------|-------------|
| 隔离级别 | 低（共享内核 Namespace） | 高（独立内核） | 极高（独立内核 + eBPF 网络隔离） |
| 启动速度 | ~200ms | 秒级 | **< 60ms**（裸金属单并发） |
| 内存开销 | 低 | 高（完整 OS） | **< 5 MiB**（极限裁剪） |
| 部署密度 | 高 | 低 | 极高（单机数千实例） |
| E2B SDK 兼容 | ✗ | ✗ | ✅ Drop-in |

## 2. 技术原理

### 2.1 底层虚拟化

CubeSandbox **基于 RustVMM + KVM** 构建 MicroVM，这与 Kata Containers 的 Cloud Hypervisor (CLH) 路线同源：

- **CubeHypervisor**：自研 VMM，基于 RustVMM crate 生态（vm-memory, kvm-ioctls, virtio-devices 等），管理 KVM MicroVM 生命周期
- **CubeShim**：实现 containerd Shim v2 API（类似 kata-runtime），将沙箱集成到容器运行时
- 致谢中明确提到 **Cloud Hypervisor** 和 **Kata Containers** 为上游基础

### 2.2 极速冷启动的关键：资源池化 + 快照克隆

CubeSandbox 60ms 冷启动的核心技术：

1. **资源池预置（Resource Pool Pre-provisioning）**：预先创建一批 MicroVM 放入资源池，请求到来时直接从池中获取，跳过 VM 创建开销
2. **快照克隆（Snapshot Cloning）**：基于 VM 快照 + Copy-on-Write 克隆，避免重复加载内核/rootfs
3. **极限裁剪 Guest Kernel/Rootfs**：最小化 Guest OS，仅保留代码执行所需组件

这解释了 < 5 MiB 内存开销——不是说 VM 本身只用 5MB，而是**增量开销**（共享基础快照，只计算 CoW 差异页）。

### 2.3 与 Kata Containers 的对比

| 维度 | Kata Containers | CubeSandbox |
|------|----------------|-------------|
| 定位 | 通用容器安全运行时（K8s Pod） | AI Agent 代码沙箱 |
| VMM | QEMU / Cloud Hypervisor | 自研 CubeHypervisor（RustVMM） |
| 容器集成 | containerd shimv2 + kata-agent | CubeShim（shimv2） |
| 网络 | tc-redirect-tap / tcfilter | CubeVS（eBPF 虚拟交换机） |
| 存储 | virtiofs / virtio-blk | 未详述 |
| 冷启动 | ~150-500ms（含 agent 就绪） | < 60ms（资源池 + 快照克隆） |
| 内存开销 | ~167-207 MiB/pod（实测） | < 5 MiB（增量 CoW） |
| K8s 集成 | RuntimeClass 原生 | 独立集群编排（CubeMaster） |
| API 兼容 | OCI / CRI | E2B SDK REST API |

**核心差异**：Kata 是 K8s 生态的通用安全容器运行时；CubeSandbox 是专为 AI Agent 短生命周期代码执行优化的沙箱服务，通过资源池预热 + 快照克隆实现极致冷启动。

## 3. 分层架构

```
┌─────────────────────────────────────────────┐
│              E2B SDK / REST Client           │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│  CubeAPI (Rust)                              │
│  E2B 兼容 REST 网关，高并发                    │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│  CubeMaster                                  │
│  集群编排调度器，资源管理 + 状态维护             │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│  CubeProxy                                   │
│  反向代理，Host 头路由到沙箱实例               │
│  TLS (mkcert) + CoreDNS (*.cube.app)        │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│  Cubelet (每节点)                             │
│  本地调度，管理沙箱生命周期                     │
├─────────────────────────────────────────────┤
│  CubeVS          │  CubeHypervisor + CubeShim│
│  eBPF 虚拟交换机  │  KVM MicroVM 管理          │
│  网络隔离 + NAT   │  containerd Shim v2        │
└─────────────────────────────────────────────┘
                   │
         ┌─────────┴─────────┐
         │  KVM MicroVM ×N   │
         │  (独立内核)        │
         └───────────────────┘
```

## 4. 网络模型 (CubeVS)

CubeVS 用 eBPF 替代传统的 Linux Bridge + iptables：

### 4.1 三个 eBPF 程序

| 程序 | 挂载点 | 方向 | 职责 |
|------|-------|------|------|
| `from_cube` (mvmtap.bpf.c) | TC ingress on TAP | 沙箱→主机 | SNAT + 策略检查 + 会话创建 + ARP 代理 |
| `from_world` (nodenic.bpf.c) | TC ingress on eth0 | 外部→主机 | 反向 NAT + 端口映射 |
| `from_envoy` (localgw.bpf.c) | TC egress on cube-dev | Overlay→沙箱 | DNAT overlay 流量到沙箱 |

额外还有 XDP 程序 `filter_from_cube` 做早期过滤。

### 4.2 无桥接点对点架构

- 每个沙箱通过独立 TAP 设备直连
- 无共享 bridge / OVS，消除交换机跳数
- SNAT 端口池化，避免 iptables 规则爆炸

### 4.3 固定内部 IP

- 沙箱内部 IP：`169.254.68.6`（Link-local）
- 网关 IP：`169.254.68.5`
- 所有沙箱使用相同内部地址，通过 TAP + NAT session 隔离

## 5. 依赖组件

- MySQL：元数据存储
- Redis：状态缓存
- Docker Compose：管理 MySQL/Redis
- CoreDNS：`*.cube.app` 域名路由
- mkcert：本地 TLS 证书

## 6. 平台支持

### ⚠️ 仅支持 x86_64

文档和安装脚本明确要求：
- **x86_64 Linux + KVM**
- 支持：裸金属服务器、WSL 2、VMware 嵌套虚拟化
- **不支持 ARM (aarch64)**

Release 资产只有一个 tarball（`cube-sandbox-one-click-b767d06.tar.gz`，~416 MB），内含 x86_64 二进制。

### 对 EC2 的影响

| EC2 类型 | 可行性 |
|----------|-------|
| m8g (Graviton ARM) | ❌ 不支持 |
| m8i.metal (x86 裸金属) | ✅ 最佳，直接 KVM |
| m8i.4xlarge (x86 虚拟机) | ⚠️ 需要 Intel 嵌套虚拟化（.metal 除外 EC2 不暴露 /dev/kvm） |
| c5.metal / m5.metal | ✅ 可用 |

**结论：需要 x86_64 bare-metal EC2 实例（如 m8i.metal, c5.metal 等）。**

## 7. 性能 Benchmark 数据（官方）

| 指标 | 数值 |
|------|------|
| 单并发冷启动 | 60ms |
| 50 并发平均 | 67ms |
| 50 并发 P95 | 90ms |
| 50 并发 P99 | 137ms |
| 内存开销（≤32GB 规格） | < 5 MiB |

## 8. 与 Kata Benchmark 的关联

CubeSandbox 脱胎于 Kata/CLH 生态，在以下方面值得对比测试：

1. **冷启动速度**：CubeSandbox 60ms vs Kata-CLH ~150ms vs Kata-QEMU ~300ms
2. **内存开销**：CubeSandbox < 5MB (CoW) vs Kata-QEMU 207MB vs Kata-CLH 167MB
3. **网络性能**：CubeVS (eBPF) vs Kata tc-redirect-tap
4. **部署密度**：单机可创建沙箱数量
5. **CPU 计算开销**：同为 KVM MicroVM，EPT 开销应一致

---

*文档生成时间：2026-04-22*  
*基于 CubeSandbox v0.1.0 公开文档和源码分析*
