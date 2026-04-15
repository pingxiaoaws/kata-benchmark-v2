# gVisor 架构与原理深度解析

**基于 gVisor 源码（github.com/google/gvisor）和官方架构文档的技术分析**

---

## 1. 什么是 gVisor？

gVisor 是 Google 开源的**容器应用内核（Application Kernel）**，为容器提供安全隔离。它既不是传统的 syscall 过滤器（如 seccomp-bpf），也不是虚拟机 hypervisor（如 QEMU/KVM），而是一种**第三条路线**：在用户态实现一个类 Linux 内核，拦截容器内应用的所有系统调用并在用户空间处理，从而将容器与宿主机内核完全隔离。

gVisor 用 **Go 语言**编写（内存安全），运行在用户态，提供了接近 VM 的安全隔离强度，同时保持了容器的轻量级和快速启动特性。

### 核心定位

```
传统容器 (runc):     应用 → [syscall] → 宿主机 Linux 内核  （共享内核，一次漏洞即可逃逸）
虚拟机 (Kata/QEMU):  应用 → Guest 内核 → [VMExit] → Hypervisor → 宿主机内核  （硬件隔离，重量级）
gVisor (runsc):      应用 → [syscall 拦截] → gVisor Sentry (用户态内核) → [极少量 syscall] → 宿主机内核  （用户态隔离，轻量级）
```

---

## 2. 整体架构

gVisor 的架构由三个核心组件组成：

```
┌──────────────────────────────────────────────┐
│            容器内应用（Application）            │
│          （认为自己运行在 Linux 上）            │
└──────────────┬───────────────────────────────┘
               │ 系统调用 (syscall)
               ▼
┌──────────────────────────────────────────────┐
│         gVisor Sentry（用户态内核）             │
│                                              │
│  ┌─────────┐ ┌─────────┐ ┌───────────────┐  │
│  │ 进程管理 │ │ 内存管理 │ │   VFS 文件系统  │  │
│  │  (PID   │ │  (MM,   │ │  (tmpfs,      │  │
│  │  table, │ │  mmap,  │ │   devfs,      │  │
│  │  signal)│ │  pgfault)│ │   procfs)     │  │
│  └─────────┘ └─────────┘ └───────────────┘  │
│  ┌─────────┐ ┌─────────┐ ┌───────────────┐  │
│  │ 网络协议栈│ │命名空间  │ │   cgroup 模拟  │  │
│  │ (netstack│ │(pid,mnt,│ │               │  │
│  │  TCP/IP) │ │ net,uts)│ │               │  │
│  └─────────┘ └─────────┘ └───────────────┘  │
│                                              │
│         全部用 Go 实现，内存安全                │
└──────┬───────────────────────────┬───────────┘
       │ 极少量宿主机 syscall        │ 9P 协议
       ▼                           ▼
┌──────────────┐           ┌───────────────┐
│  宿主机 Linux  │           │  Gofer 进程    │
│    内核       │           │  (文件系统代理)  │
│              │           │  稍高权限运行    │
│  seccomp +   │           │  负责宿主机文件  │
│  namespace   │           │  的实际 I/O     │
│  限制 Sentry  │           └───────────────┘
└──────────────┘
```

### 2.1 Sentry（哨兵 — 核心组件）

Sentry 是 gVisor 的核心，是一个**完整的用户态 Linux 内核重新实现**：

- **系统调用处理**：实现了 200+ 个 Linux 系统调用（getpid、read、write、mmap、fork、exec 等），全部在用户空间完成
- **进程管理**：维护自己的 PID 表、进程树、信号处理。容器内的进程在宿主机上不可见（`top` 看不到）
- **内存管理**：实现虚拟内存、mmap、page fault 处理、copy-on-write
- **VFS 文件系统**：实现 tmpfs、devfs、procfs、sysfs 等虚拟文件系统
- **网络协议栈（netstack）**：用 Go 从零实现的完整 TCP/IP 协议栈，不依赖宿主机网络栈
- **命名空间**：PID namespace、mount namespace、network namespace、UTS namespace 等

**关键设计原则：没有任何系统调用被直接透传到宿主机。** 每个系统调用都有独立的 Sentry 内实现。例如：
- 容器调用 `getpid()` → Sentry 查自己的 PID 表返回，**不调用宿主机的 getpid**
- 容器调用 `read(fd)` → Sentry 可能调用宿主机的 `futex()` 做同步，但参数和语义完全由 Sentry 控制

Sentry 本身运行在极度受限的环境中：
- 使用 seccomp-bpf 过滤自身的系统调用（禁止 exec、connect 等）
- 运行在隔离的 mount namespace、user namespace 中
- 最小化 capabilities

### 2.2 Gofer（文件系统代理）

Gofer 是 Sentry 的**伴随进程**，运行在比 Sentry 稍高权限的环境中，负责：

- 代理文件系统操作（打开文件、读写目录）
- 通过 9P 协议与 Sentry 通信
- Sentry 本身无法直接访问宿主机文件系统

这种分离设计确保了即使 Sentry 被攻破，攻击者也无法直接访问文件系统——还需要再攻破 Gofer 进程。

### 2.3 runsc（OCI 运行时）

runsc 是 gVisor 的 OCI 兼容容器运行时，类似于 runc：

- 实现 OCI Runtime Specification
- 可直接替换 runc 用于 Docker 和 Kubernetes
- 负责创建 sandbox、启动 Sentry 和 Gofer、管理容器生命周期

---

## 3. 系统调用拦截机制（Platforms）

gVisor 需要一种机制来拦截容器应用的系统调用并转交给 Sentry 处理。这个机制称为 **Platform**，目前支持三种实现：

### 3.1 Systrap（默认，推荐）

```
应用线程执行 syscall
        ↓
seccomp-bpf 触发 SECCOMP_RET_TRAP
        ↓
内核发送 SIGSYS 信号给该线程
        ↓
信号处理函数将控制权交给 Sentry
        ↓
Sentry 处理系统调用，返回结果
        ↓
应用线程继续执行
```

- **原理**：利用 seccomp-bpf 的 `SECCOMP_RET_TRAP` 模式，将系统调用转化为信号（SIGSYS），由 Sentry 的信号处理函数接管
- **优点**：不需要硬件虚拟化支持，**适合在 VM 内运行**（如 EC2 实例）
- **性能**：中等，优于 ptrace，略逊于 KVM
- 2023 年中期成为默认平台

### 3.2 KVM

```
应用代码在 Guest Ring 3 运行
        ↓
执行 syscall 触发 VM Exit
        ↓
Sentry（作为 VMM）处理 VM Exit
        ↓
Sentry 执行系统调用逻辑
        ↓
返回 Guest Ring 3 继续执行
```

- **原理**：利用 Linux KVM 子系统，Sentry 同时充当 Guest OS 和 VMM。应用代码在 Guest Ring 3 中运行，系统调用触发 VM Exit 由 Sentry 处理
- **优点**：裸金属上性能最好（利用硬件虚拟化加速上下文切换）
- **缺点**：需要 KVM 支持，在嵌套虚拟化环境下性能不如 Systrap
- **注意**：虽然使用了 KVM，但 gVisor **不运行 guest kernel**，没有设备模拟，不是传统 VM

### 3.3 ptrace（已弃用）

- **原理**：使用 `PTRACE_SYSEMU` 拦截系统调用
- **优点**：兼容性最好，任何环境都能跑
- **缺点**：上下文切换开销极高
- 已被 Systrap 取代，预计将从代码库中移除

### Platform 选择建议

| 环境 | 推荐 Platform |
|------|-------------|
| 裸金属服务器 | KVM（性能最优） |
| 虚拟机内（EC2/GCE） | **Systrap**（默认，无需嵌套虚拟化） |
| 无虚拟化支持 | Systrap |
| 嵌套虚拟化 | Systrap（KVM 在嵌套下性能差） |

---

## 4. 网络架构（netstack）

gVisor 实现了自己的 **完整 TCP/IP 协议栈**，称为 netstack，位于源码 `pkg/tcpip/` 目录：

```
容器应用
    ↓ socket API (由 Sentry 实现)
┌─────────────────────────┐
│      gVisor netstack     │
│  ┌────┐ ┌────┐ ┌──────┐ │
│  │TCP │ │UDP │ │ICMP  │ │
│  └──┬─┘ └──┬─┘ └──┬───┘ │
│     └───┬──┘      │     │
│      ┌──┴──┐   ┌──┴──┐  │
│      │ IPv4│   │IPv6 │  │
│      └──┬──┘   └──┬──┘  │
│         └───┬─────┘     │
│          ┌──┴──┐        │
│          │ ARP │        │
│          └──┬──┘        │
│          ┌──┴──────┐    │
│          │ 虚拟网卡  │    │
│          │ (veth)  │    │
│          └──┬──────┘    │
└─────────────┼───────────┘
              ↓ 原始以太网帧
         宿主机网络设备
```

- **完全用 Go 实现**，从以太网帧解析到 TCP 状态机管理
- 不依赖宿主机的 iptables、conntrack 等
- 支持 IPv4/IPv6、TCP、UDP、ICMP
- 容器内可以正常使用 socket API

---

## 5. 文件系统架构

```
容器应用
    ↓ open/read/write/stat
┌─────────────────────────────┐
│     Sentry VFS (虚拟文件系统) │
│                             │
│  ┌──────────────────────┐   │
│  │ 内核文件系统            │   │
│  │ tmpfs, devfs, procfs  │   │
│  │ sysfs (部分)          │   │
│  └──────────────────────┘   │
│  ┌──────────────────────┐   │
│  │ 远程文件系统            │   │
│  │ 通过 9P/LISAFS 协议    │   │
│  │ 与 Gofer 通信          │   │
│  └──────────┬───────────┘   │
└─────────────┼───────────────┘
              ↓ 9P 协议
┌─────────────────────────────┐
│      Gofer 进程              │
│  实际执行宿主机文件 I/O       │
│  (open, read, write, stat)  │
└─────────────────────────────┘
```

- tmpfs、devfs、procfs 等由 Sentry 内部实现，不经过 Gofer
- 容器挂载的宿主机目录通过 Gofer + 9P 协议访问
- **DirectFS 模式**：可选的高性能模式，允许 Sentry 直接访问文件系统（减少 9P 开销）

---

## 6. 安全模型

### 6.1 威胁模型

gVisor 的安全目标是**防止容器内的恶意代码利用宿主机内核漏洞逃逸**。

传统容器的问题：

```
恶意容器 → syscall → 宿主机内核漏洞 → 容器逃逸 → 完全控制宿主机
           ↑
     一次漏洞即可逃逸
```

gVisor 的防御：

```
恶意容器 → syscall → gVisor Sentry (Go, 内存安全)
                          ↓
                    即使攻破 Sentry，还需要：
                          ↓
                    突破 seccomp-bpf 限制
                          ↓
                    突破 namespace 隔离
                          ↓
                    利用宿主机内核漏洞
                          ↓
                    容器逃逸（需要多层突破）
```

### 6.2 纵深防御原则

1. **所有系统调用由 Sentry 独立实现**：不透传到宿主机，即使宿主机内核有漏洞也无法直接触发
2. **Sentry 对宿主机的系统调用极少且受 seccomp 严格限制**：不允许 exec、connect、open 等
3. **Sentry 用 Go 编写**：消除 C/C++ 常见的内存安全漏洞（buffer overflow、use-after-free 等）
4. **代码审计严格**：
   - 不允许 CGo
   - unsafe 代码隔离在 `_unsafe.go` 文件中
   - 核心包不允许外部导入
5. **持续模糊测试（fuzzing）**：主动发现潜在的 bug 和竞态条件

### 6.3 gVisor 不能防御什么？

| 威胁类型 | 能否防御 | 说明 |
|---------|---------|------|
| 内核 syscall 漏洞利用 | ✅ 能 | 核心设计目标 |
| 容器逃逸 | ✅ 能 | 多层隔离 |
| CPU 侧信道攻击 (Spectre/Meltdown) | ❌ 不能 | 需要宿主机/硬件级别缓解 |
| 应用层漏洞 (如 PHP 漏洞) | ❌ 不能 | 攻击者仍可访问容器内资源 |
| 上层组件漏洞 (如 containerd) | ❌ 不能 | 在 gVisor 之前就被攻破 |
| 资源耗尽/DoS | ❌ 不能 | 依赖宿主机 cgroup 限制 |

### 6.4 与 VM 安全性对比

| 维度 | gVisor | VM (Kata/QEMU) |
|------|--------|----------------|
| 隔离边界 | 用户态内核 + seccomp + namespace | 硬件虚拟化 (VT-x/AMD-V) |
| 逃逸难度 | 需攻破 Go 用户态程序 + 宿主机 seccomp | 需 VM 逃逸 (极难) |
| 攻击面 | Sentry 的 Go 代码 | VMM (QEMU) 的 C 代码 + 设备模拟 |
| 内存安全 | Go 内存安全 ✅ | QEMU 用 C 写 ❌ |
| 代码量 | 较小（Go 实现） | 庞大（QEMU 200万行 C） |

gVisor 的观点：VM 并不天然更安全 — QEMU 的设备模拟代码（C 语言）比简单的系统调用更复杂，且 userspace VMM 通常没有沙箱化。gVisor 虽然不用硬件虚拟化，但通过内存安全语言 + 最小化攻击面 + 纵深防御实现了强隔离。

---

## 7. 源码结构

gVisor 使用 Bazel 构建，主要目录结构：

```
gvisor/
├── runsc/                    # OCI 运行时入口 (runsc 命令)
│   ├── boot/                 # sandbox 启动逻辑
│   ├── cmd/                  # 子命令 (create, start, run, exec...)
│   └── sandbox/              # sandbox 管理
├── pkg/
│   ├── sentry/               # ★ Sentry 核心 — 用户态内核
│   │   ├── kernel/           # 进程管理、信号、线程
│   │   ├── mm/               # 内存管理 (mmap, page fault)
│   │   ├── vfs/              # 虚拟文件系统框架
│   │   ├── fsimpl/           # 文件系统实现 (tmpfs, devfs, procfs...)
│   │   ├── socket/           # socket 接口层
│   │   ├── syscalls/         # ★ 系统调用实现 (200+)
│   │   │   └── linux/        # Linux syscall 处理函数
│   │   ├── platform/         # ★ 平台抽象 (syscall 拦截机制)
│   │   │   ├── systrap/      # Systrap 平台实现
│   │   │   ├── kvm/          # KVM 平台实现
│   │   │   └── ptrace/       # ptrace 平台实现 (已弃用)
│   │   ├── arch/             # CPU 架构相关 (x86_64, arm64)
│   │   └── time/             # 时间子系统
│   ├── tcpip/                # ★ netstack — 完整 TCP/IP 协议栈
│   │   ├── transport/        # TCP, UDP
│   │   ├── network/          # IPv4, IPv6, ARP
│   │   ├── link/             # 链路层 (ethernet, loopback)
│   │   ├── stack/            # 协议栈核心
│   │   └── header/           # 协议头解析
│   ├── lisafs/               # LISA 文件系统协议 (9P 替代)
│   └── hostarch/             # 宿主机架构相关
├── shim/                     # containerd shim (containerd-shim-runsc-v1)
├── tools/                    # 构建和分析工具
└── test/                     # 测试套件 (syscall 兼容性测试等)
```

### 关键代码路径

**系统调用处理流程**：
```
pkg/sentry/platform/systrap/  → 拦截 syscall (SIGSYS 信号)
pkg/sentry/kernel/task_syscall.go → 分发到对应处理函数
pkg/sentry/syscalls/linux/     → 200+ syscall 实现
  ├── sys_read.go              → read()
  ├── sys_write.go             → write()
  ├── sys_mmap.go              → mmap()
  ├── sys_socket.go            → socket()
  ├── sys_file.go              → open/close/stat
  └── ...
```

**网络数据路径**：
```
应用 send() → pkg/sentry/socket/ → pkg/tcpip/transport/tcp/ → pkg/tcpip/network/ipv4/ → pkg/tcpip/link/ → 宿主机网卡
```

---

## 8. 性能特征

### 8.1 开销来源

| 开销类型 | 原因 | 影响程度 |
|---------|------|---------|
| syscall 拦截 | 每次 syscall 需要上下文切换到 Sentry | syscall 密集型应用影响大 |
| Go 运行时 | GC、goroutine 调度 | 内存和延迟有波动 |
| 用户态网络栈 | netstack 不如内核网络栈优化 | 网络密集型有 20-30% 开销 |
| 文件系统代理 | 9P 协议增加文件 I/O 延迟 | I/O 密集型影响明显 |

### 8.2 适合 vs 不适合的场景

| ✅ 适合 | ❌ 不适合 |
|--------|----------|
| CPU 密集型计算 | syscall 极密集型 (高频 I/O) |
| Web 服务 / API | 需要完整 Linux 内核特性 |
| 多租户隔离 | 需要特定 ioctl / 设备访问 |
| CI/CD 构建任务 | 高频交易系统 |
| 运行不可信代码 | 需要内核模块 |

### 8.3 与 Kata Containers 性能对比（我们的 benchmark 数据）

| 指标 | runc | gVisor | kata-qemu | kata-clh |
|------|------|--------|-----------|----------|
| **Pod 密度 (m8i.2xlarge)** | N/A | **14** | 7 | 13 |
| **网络吞吐** | 86 Gbps | 59 Gbps (-31%) | 32 Gbps (-50%) | 17 Gbps (-74%) |
| **网络延迟** | 0.06 ms | 0.39 ms (6.4x) | 0.65 ms (13x) | 0.68 ms (13x) |
| **启动时间** | ~100ms | ~200ms | ~2-5s | ~1-3s |
| **内存 Overhead/Pod** | 0 | ~0 | ~207 MiB | ~167 MiB |
| **需要 KVM** | 否 | 否* | 是 | 是 |

> *gVisor 默认用 Systrap 不需要 KVM，可选 KVM 平台提升性能

---

## 9. Kubernetes 集成

### 9.1 RuntimeClass

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    runtime: gvisor
  tolerations:
  - key: gvisor
    value: "true"
    effect: NoSchedule
```

### 9.2 containerd 配置

```toml
# containerd 2.x (新 namespace)
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
runtime_type = "io.containerd.runsc.v1"

# containerd 1.x (旧 namespace)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
runtime_type = "io.containerd.runsc.v1"
```

### 9.3 Pod 使用

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  runtimeClassName: gvisor
  containers:
  - name: app
    image: nginx:latest
```

### 9.4 托管服务支持

| 平台 | 支持方式 |
|------|---------|
| **GKE** | GKE Sandbox（原生集成，一键开启） |
| **EKS** | 需手动安装 runsc + 配置 containerd + nodeadm |
| **AKS** | 需手动安装（类似 EKS） |
| **Minikube** | `minikube addons enable gvisor` |

---

## 10. 与其他沙箱运行时对比

| 维度 | gVisor (runsc) | Kata Containers | Firecracker |
|------|---------------|-----------------|-------------|
| **隔离机制** | 用户态内核 | 轻量 VM (KVM) | 微 VM (KVM) |
| **安全边界** | Go 用户态进程 | 硬件虚拟化 | 硬件虚拟化 |
| **Guest 内核** | 无（Sentry 即内核） | 完整 Linux 内核 | 完整 Linux 内核 |
| **内存安全** | ✅ Go | ❌ C (QEMU/CLH) | ✅ Rust |
| **OCI 兼容** | ✅ | ✅ | ❌（需通过 Kata 或 firecracker-containerd） |
| **K8s 集成** | ✅ RuntimeClass | ✅ RuntimeClass | 间接（通过 Kata） |
| **需要 KVM** | 否（默认 Systrap） | 是 | 是 |
| **嵌套虚拟化** | 不需要 | 需要（EC2 上） | 需要（EC2 上） |
| **启动时间** | ~200ms | 2-5s | <125ms |
| **内存 Overhead** | 极低 | 150-250 MiB/pod | ~5 MiB/VM |
| **syscall 兼容** | ~200+（部分） | 完整 | 完整 |
| **网络性能** | 良好 | 中等 | 良好 |
| **典型用途** | GKE Sandbox, 多租户 | 强隔离, 合规 | AWS Lambda/Fargate |
| **开发方** | Google | OpenInfra Foundation | Amazon |

---

## 11. 总结

gVisor 代表了容器安全隔离的**第三条路线**——既不是简单的 seccomp 过滤，也不是重量级的 VM 虚拟化，而是用内存安全语言在用户态重新实现 Linux 内核接口。

**核心优势：**
- 零 VM 开销，秒级启动
- Go 语言内存安全，消除最大类别安全漏洞
- 不需要硬件虚拟化，任何 Linux 环境可用
- 与容器生态无缝集成（OCI, Docker, K8s）

**核心权衡：**
- syscall 密集型场景有性能开销
- 不支持所有 Linux syscall（~200+ vs 内核 400+）
- 报告 Linux 4.4.0 内核版本，某些依赖内核版本检测的软件可能不兼容
- 安全隔离强度略低于硬件 VM（但 gVisor 认为这不是绝对的）

**适用场景排序：**
1. 🥇 多租户 SaaS/PaaS 隔离（GKE Sandbox 核心用途）
2. 🥈 运行不可信代码（CI/CD、用户提交的代码）
3. 🥉 纵深防御（在信任代码外再加一层保护）
4. 开发测试环境快速隔离
