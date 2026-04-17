# gVisor + EFS 深度排查 Q&A

本文档记录了排查 gVisor + EFS `Operation not permitted` 问题过程中的关键讨论和技术分析。

---

## Q1: gVisor 之前的满载测试中 EFS 挂载显示 OK，为什么实际不能读写？

之前的满载测试（`stress-test/graviton-gvisor-efs/`）中 `efs_mount_ok=OK` **仅验证了 EFS PVC 挂载点存在**（mount 点可见），但没有实际执行文件读写操作。stress-ng 的工作负载是 CPU + 内存压测（`--vm-bytes`），不涉及 EFS 文件 I/O。

当我们用 fio / dd / touch 实际写 EFS 时，才发现 `Operation not permitted`。

---

## Q2: gVisor DirectFS 模式能否使用？DirectFS 和 9P 是什么关系？

**DirectFS 已经在使用中。** Pod 内 `mount` 显示的 `9p` 和 DirectFS 不是互斥的，而是不同层级：

```
容器内 mount 显示:  /efs type 9p rw,...,directfs    ← gVisor VFS 层的标识

实际 I/O 路径（DirectFS 开启时）:
  Sentry → 直接 host openat()/write() syscall → Host NFS4 client → EFS

实际 I/O 路径（DirectFS 关闭时）:
  Sentry → LISAFS RPC → Gofer 进程 → host syscall → Host NFS4 client → EFS
```

确认方式：
- `runsc flags | grep directfs` → `-directfs (default true)`
- gofer cmdline 中 `--gofer-mount-confs=lisafs:none` 表示用 LISAFS 协议、无 overlay
- mount 选项末尾有 `directfs` 标志

参考：[Optimizing gVisor filesystems with Directfs](https://opensource.googleblog.com/2023/06/optimizing-gvisor-filesystems-with-directfs.html)

DirectFS 的设计初衷是**优化本地文件系统性能**（减少 gofer RPC 开销），文章明确说 *"all the filesystems served by the gofer are mounted locally on the host"*。对 NFS/EFS 这种远程文件系统，DirectFS 的客户端侧权限检查会与 NFS 服务端的 uid 映射语义冲突。

---

## Q3: Node 上的 mount 信息是什么样的？Pod 内看到的 9p 是 Node 上的还是 Pod 内的？

**Pod 内 `mount` 看到的是 gVisor sentry 内部的虚拟文件系统，不是 Node 的真实 mount。**

### Node 上（host mount namespace）：
```
# gvisor pod 的 EFS — 真实 NFS4
127.0.0.1:/ on /var/lib/kubelet/pods/<pod-uid>/.../mount
  type nfs4 (rw,relatime,vers=4.1,rsize=1048576,wsize=1048576,sec=sys,...)

# gvisor pod 的 EBS — 真实 ext4  
/dev/nvme1n1 on /var/lib/kubelet/pods/<pod-uid>/.../mount
  type ext4 (rw,relatime,seclabel)
```

### Gofer 进程 mount namespace：
```
overlay /       overlay  ro,...          # container rootfs
/dev/nvme1n1 /ebs  ext4   rw,seclabel   # EBS 直接挂载
127.0.0.1:/ /efs   nfs4   rw,nosuid,... # EFS NFS4 也传进 gofer
```

### Sandbox (sentry) mount namespace：
```
runsc-root / tmpfs ro,seclabel,relatime   # 空 tmpfs — pivot_root 隔离
```
Sentry 自己的 mount namespace 是空的，它通过 gofer 传来的 file descriptor 访问文件系统。

### Pod 内（gVisor VFS）：
```
none /efs 9p rw,...,directfs   # gVisor VFS 层标识，不是真实 9P
```

---

## Q4: EFS Access Point 是什么？它怎么影响权限？

EFS Access Point (AP) 是 EFS 的应用级入口点，从我们的 StorageClass 配置看：

```yaml
parameters:
  provisioningMode: efs-ap    # 动态创建 Access Point
  fileSystemId: fs-077bd850b7bb23b4f
  uid: "1000"                 # AP 强制 uid
  gid: "1000"                 # AP 强制 gid
  directoryPerms: "700"       # AP 创建目录权限
  basePath: /openclaw
```

AP 的核心行为：**无论 NFS 客户端发送什么 uid，EFS 服务端都将其映射为 AP 配置的 uid/gid（1000:1000）**。

这就是为什么 runc 中 root (uid=0) 写 EFS 成功后，文件 owner 显示为 1000：
```bash
# runc pod
$ id → uid=0(root)
$ touch /efs/test && ls -la /efs/test
-rw-r--r--. 1 1000 1000 0 /efs/test   # ← EFS AP 将 uid=0 映射为 1000
```

---

## Q5: runc 的 Pod 是以 uid=1000 跑的吗？为什么 uid=0 可以成功？

**不是，runc pod 也是 uid=0 (root)。** 关键区别在于权限检查的位置：

### runc 路径：
```
容器 uid=0 → host kernel NFS4 client (发送 NFS RPC, auth uid=0)
  → EFS 服务端 → AP 强制映射 uid=0→1000
  → 检查: uid=1000 vs 目录 owner=1000, mode=0700 → ✅ 通过
```
权限检查**完全在 EFS 服务端**，AP 的 uid 映射在检查之前生效。

### gVisor DirectFS 路径：
```
Sentry uid=0 → 准备 openat() syscall
  → gVisor sentry 先查看目录 metadata（从 NFS getattr 获得: owner=1000, mode=0700）
  → 客户端侧 POSIX 权限检查: uid=0 != owner 1000, others 无 w 权限
  → ❌ EPERM（NFS 写请求未发出，EFS AP uid 映射没有机会生效）
```

**根因：gVisor sentry 在发出 host syscall 前做了额外的客户端侧 POSIX 权限检查，而 NFS 的设计意图是把权限检查交给服务端。**

---

## Q6: 修改 EFS Access Point 权限为 0755 能解决吗？

**不能。** 我们创建了 `efs-sc-755` StorageClass 测试：

```
# directoryPerms=755 后
drwxr-xr-x. 2 1000 1000 /efs   # 755: owner=rwx, group=r-x, others=r-x
```

gVisor pod (uid=0) 仍然 EPERM，因为 `0755` 给 others 的是 `r-x`（读+执行），**没有写权限 `w`**。

理论上 `0777` 可能有效（others 有 rwx），但这意味着完全放开权限，**不建议在生产环境使用**。

---

## Q7: gVisor 的 EFS/EBS fio 性能为什么比 runc 高这么多？

gVisor 的 fio 数据异常高（EFS 顺序读 46 GiB/s, EBS 顺序读 35 GiB/s）是因为**缓存效应**：

1. **gVisor 不支持 O_DIRECT**：即使 fio 指定 `--direct=1`，gVisor 内核会忽略这个 flag，所有 I/O 走页缓存
2. **gVisor 9p/lisafs VFS 层有激进的客户端缓存**：`cache=remote_revalidating` 模式下，读操作大量命中内存缓存
3. **runc 的 `direct=1` 真的绕过页缓存**：所以 runc 的数据反映了存储后端的真实性能

| 存储 | runc (真实 I/O) | gVisor (缓存 I/O) | 说明 |
|------|----------------|-------------------|------|
| EBS gp3 seq-write | 127 MiB/s | 6,080 MiB/s | gp3 基线 125 MiB/s |
| EFS seq-write | 1,697 MiB/s | 12,733 MiB/s | EFS 含 NFS 客户端缓存 |

**两者不可直接对比。** 但这说明 gVisor 在缓存命中场景（如重复读取同一数据集）下延迟极低，对读密集型工作负载有利。

---

## Q8: Sandbox 的 uid_map 显示 1:1 映射，User Namespace 不是问题的根因？

正确。Sandbox 的 uid_map：
```
0    0    4294967295   # 容器 uid 0 = host uid 0, 全范围 1:1 映射
```

这意味着 sentry 进程在 host 上就是 uid=0（真实 root），不存在 user namespace 的 uid 重映射问题。

问题出在 **gVisor sentry 代码内部的权限检查逻辑**，而不是 Linux 内核的 user namespace 机制。

---

## Q9: 生产环境推荐什么方案？

| 场景 | 推荐方案 |
|------|---------|
| gVisor + EFS | `runAsUser`/`runAsGroup` 匹配 EFS AP 的 uid/gid |
| gVisor + 块存储 | 使用 EBS (gp3)，无权限问题 |
| gVisor + 不需要持久化 I/O | 不挂 EFS，或只读挂载 |
| 需要 root 运行 + EFS | 使用 runc，不用 gVisor |

最佳实践：
```yaml
# EFS StorageClass
parameters:
  uid: "1000"
  gid: "1000"
  directoryPerms: "700"

# Pod spec
securityContext:
  runAsUser: 1000      # 必须匹配 SC 的 uid
  runAsGroup: 1000     # 必须匹配 SC 的 gid
```

这也符合安全最佳实践：容器不应以 root 运行。
