# gVisor + EFS I/O 测试报告

## 测试概述

测试 gVisor 运行时在 EKS 上访问 EFS (NFS4) 共享存储的能力，对比 runc 基线，定位 gVisor + EFS 写入 `Operation not permitted` 的根因，并提供解决方案。

**测试日期**: 2026-04-16 ~ 2026-04-17

## 环境

| 项目 | 值 |
|------|-----|
| 集群 | test-s4, EKS 1.34, us-west-2 |
| 节点 | ip-172-31-9-46.us-west-2.compute.internal |
| 实例类型 | m7g.2xlarge (Graviton, arm64, 8 vCPU, 32 GiB) |
| gVisor 版本 | release-20260406.0 (DirectFS 默认启用) |
| EFS | fs-077bd850b7bb23b4f, StorageClass `efs-sc` |
| EFS AP 配置 | uid=1000, gid=1000, directoryPerms=700, basePath=/openclaw |
| EBS | gp3, 20 GiB |
| fio 版本 | 3.28 (apt install) |
| fio 参数 | ioengine=psync, iodepth=1, numjobs=4, runtime=60s, size=1G |

## 测试过程

### 阶段 1：gVisor + EFS 写入失败排查

#### 1.1 初始发现

gVisor pod 挂载 EFS PVC 后，所有写操作报 `Operation not permitted`：

```bash
# Pod 内执行（uid=0, root）
$ dd if=/dev/zero of=/efs/test bs=4k count=1
dd: failed to open '/efs/test': Operation not permitted

$ touch /efs/test
touch: setting times of '/efs/test': No such file or directory

$ python3 -c "import os; os.open('/efs/test', os.O_WRONLY|os.O_CREAT, 0o644)"
OSError: [Errno 1] Operation not permitted
```

同时验证：
- gVisor + EBS (ext4)：✅ 读写正常
- gVisor + tmpfs：✅ 读写正常
- runc + EFS (NFS4)：✅ 读写正常（uid=0）

#### 1.2 Host 层 Mount 对比

**Node 上（host mount namespace）：**
```
# gvisor pod 的 EFS
127.0.0.1:/ on /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc>/mount
  type nfs4 (rw,relatime,vers=4.1,sec=sys,...)

# gvisor pod 的 EBS
/dev/nvme1n1 on /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc>/mount
  type ext4 (rw,relatime,seclabel)
```

**Gofer 进程 mount namespace：**
```
overlay /        overlay  ro,...          # rootfs
/dev/nvme1n1 /ebs   ext4   rw,seclabel   # EBS - 直接挂载
127.0.0.1:/ /efs    nfs4   rw,nosuid,... # EFS - NFS4 也传进 gofer
```

**Sandbox（sentry）进程 mount namespace：**
```
runsc-root / tmpfs ro,seclabel,relatime   # 空 tmpfs（pivot_root 隔离）
```

**Pod 内（gVisor VFS）：**
```
none /efs 9p rw,...,directfs   # gVisor 内部用 9p 呈现，实际走 DirectFS
```

#### 1.3 DirectFS 模式确认

```
$ runsc flags | grep directfs
  -directfs   directly access the container filesystems from the sentry. (default true)
```

DirectFS 已启用。Sentry 通过 gofer 传来的 file descriptor 直接对 host NFS4 mount 执行 syscall。

#### 1.4 UID/Capabilities 分析

```
# Sandbox 进程
Uid: 0 0 0 0   (uid_map: 0 0 4294967295, 即 1:1 映射)
CapEff: 000000000008001f  (CAP_CHOWN|DAC_OVERRIDE|FSETID|FOWNER|SETUID)

# Gofer 进程
Uid: 0 0 0 0
CapEff: 000000000004001f  (CAP_CHOWN|DAC_OVERRIDE|FSETID|FOWNER|SYS_CHROOT)
```

#### 1.5 EFS 目录权限

```
# Gofer 看到的 /efs
drwx------. 2 ec2-user(1000) ec2-user(1000) 6144 /efs   # mode=0700, owner=1000
```

### 阶段 2：根因定位

#### runc vs gVisor 的关键差异

```bash
# runc pod: uid=0 写 EFS 成功，文件 owner 自动变为 1000
$ kubectl exec runc-debug -- bash -c 'id; touch /efs/test; ls -la /efs/test'
uid=0(root) gid=0(root)
-rw-r--r--. 1 1000 1000 0 /efs/test   # ← EFS AP 将 uid=0 映射为 1000
```

| 层级 | runc | gVisor DirectFS |
|------|------|----------------|
| 容器 uid | 0 (root) | 0 (root) |
| I/O 路径 | 容器 → host NFS4 client → EFS 服务端 | sentry → openat() on NFS4 FD → host NFS4 client → EFS 服务端 |
| 权限检查位置 | **EFS 服务端**（AP 先映射 uid=0→1000，再检查） | **gVisor sentry 客户端侧先检查**（看到 owner=1000, mode=0700, 请求者 uid=0 → EPERM） |
| 结果 | ✅ | ❌ EPERM（NFS 请求未发出） |

**根因：gVisor sentry 在执行 host syscall 前，会在客户端侧做 POSIX 权限检查。它看到 NFS 返回的目录 metadata（owner=1000, mode=0700），判断 uid=0 不是 owner 且 others 无 w 权限，直接返回 EPERM。NFS 写请求根本没到 EFS 服务端，EFS AP 的 uid 映射机制没有机会生效。**

这是 gVisor 安全模型的设计选择：sentry 不信任远程文件系统的权限语义（如 NFS 的 root squash / uid mapping），在本地严格执行 POSIX 权限检查。

### 阶段 3：解决方案验证

#### 方案 A：修改 directoryPerms=755 ❌

创建新 StorageClass `efs-sc-755`（directoryPerms=755），gVisor pod (uid=0) 仍然 EPERM：

```
drwxr-xr-x. 2 1000 1000 /efs   # 755, others 有 r-x 但无 w
$ dd if=/dev/zero of=/efs/test → Operation not permitted
```

目录权限 755 只给 others 读+执行，不给写。改成 777 可能有效但不安全。

#### 方案 B：runAsUser=1000 ✅

Pod securityContext 设置 `runAsUser: 1000`：

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
```

```bash
$ id
uid=1000(testuser) gid=1000(testuser)
$ touch /efs/test → ✅
$ dd if=/dev/zero of=/efs/dd_test bs=4k count=10 → ✅ 5.1 MB/s
```

容器进程 uid=1000 匹配 EFS AP 的 owner=1000，gVisor 客户端侧权限检查通过。

## 测试结果

### EFS fio 性能对比

fio 参数：ioengine=psync, direct=0, iodepth=1, numjobs=4, runtime=60s, size=1G

| 测试 | runc EFS (uid=0) | gVisor EFS (uid=1000) | 对比 |
|------|-----------------|----------------------|------|
| 顺序写 1M | 1,697 MiB/s, 1,697 IOPS | 12,733 MiB/s, 12,733 IOPS | gVisor 7.5x |
| 顺序读 1M | 3,650 MiB/s, 3,650 IOPS | 46,236 MiB/s, 46,236 IOPS | gVisor 12.7x |
| 随机写 4K | 250 MiB/s, 63,902 IOPS | 762 MiB/s, 195,113 IOPS | gVisor 3.1x |
| 随机读 4K | 10.8 MiB/s, 2,768 IOPS | 151 MiB/s, 38,707 IOPS | gVisor 14x |

> ⚠️ **重要说明**：gVisor 数据显著高于 runc，原因是 gVisor 的 9p/lisafs VFS 层有激进的客户端缓存。`psync` + `direct=0` 情况下，大部分 I/O 命中 gVisor 内部缓存而非真实 NFS 网络 I/O。runc 数据更接近 EFS 真实性能。两者的 fio 数据**不可直接对比**，但说明 gVisor 在缓存命中场景下 I/O 延迟极低。

### EBS fio 性能对比

fio 参数：ioengine=psync, direct=1, iodepth=32, numjobs=4, runtime=60s, size=1G

| 测试 | runc EBS | gVisor EBS | 对比 |
|------|---------|-----------|------|
| 顺序写 1M | 127 MiB/s | 6,080 MiB/s | gVisor 48x |
| 顺序读 1M | 126 MiB/s | 34,969 MiB/s | gVisor 278x |
| 随机写 4K | 11.9 MiB/s, 3,045 IOPS | 784 MiB/s, 200,790 IOPS | gVisor 66x |
| 随机读 4K | 11.9 MiB/s, 3,044 IOPS | 1,141 MiB/s, 292,152 IOPS | gVisor 96x |

> ⚠️ **同样说明**：gVisor 拦截了 `O_DIRECT` flag（gVisor 内核不支持 direct I/O），实际走了页缓存。runc 的 127 MiB/s 是 gp3 EBS 的真实 direct I/O 性能（gp3 基线: 125 MiB/s throughput, 3,000 IOPS）。

### I/O 兼容性矩阵

| 运行时 | EFS (uid=0) | EFS (uid=1000) | EBS | tmpfs |
|--------|-----------|---------------|-----|-------|
| runc | ✅ | ✅ | ✅ | ✅ |
| gVisor | ❌ EPERM | ✅ | ✅ | ✅ |

## 结论

### 根因

gVisor DirectFS 模式下，sentry 在客户端侧严格执行 POSIX 权限检查，不理解 NFS/EFS 的服务端 uid 映射语义。当容器以 root (uid=0) 运行时，sentry 看到 EFS 目录 owner=1000、mode=0700，判断 uid=0 无写权限并返回 EPERM，NFS 写请求未到达 EFS 服务端。

### 解决方案

| 方案 | 可行性 | 说明 |
|------|--------|------|
| `runAsUser` 匹配 EFS AP uid | ✅ **推荐** | 容器 uid 与 EFS AP uid 一致（如 1000），权限检查通过 |
| `directoryPerms=755/777` | ❌/⚠️ | 755 无效（others 无 w），777 可能有效但不安全 |
| 使用 EBS 替代 EFS | ✅ 备选 | gVisor + EBS 完全正常，但 EBS 是 ReadWriteOnce |
| 关闭 DirectFS (`-directfs=false`) | ❓ 未测试 | 可能绕过客户端权限检查，但会降低性能 |

### 生产建议

```yaml
# gVisor + EFS Pod 配置示例
apiVersion: v1
kind: Pod
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsUser: 1000      # 必须匹配 EFS StorageClass 的 uid
    runAsGroup: 1000     # 必须匹配 EFS StorageClass 的 gid
  containers:
  - name: app
    image: your-image
    volumeMounts:
    - name: efs
      mountPath: /data
  volumes:
  - name: efs
    persistentVolumeClaim:
      claimName: your-efs-pvc
```

对应 EFS StorageClass：
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-xxx
  uid: "1000"
  gid: "1000"
  directoryPerms: "700"
  basePath: /your-path
provisioner: efs.csi.aws.com
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `README.md` | 本报告 |
| `efs-fio-benchmark.sh` | EFS/EBS fio 测试脚本 |
| `results-runc-efs-fio.csv` | runc EFS fio 结果（含 gVisor uid=0 失败记录） |
| `results-gvisor-efs-fio-uid1000.csv` | gVisor EFS fio 结果（uid=1000） |
| `results-ebs-fio.csv` | gVisor vs runc EBS fio 结果 |
| `test-efs-fio.log` | EFS fio 执行日志（Phase 1: gVisor 失败, Phase 2: runc 成功） |
| `test-efs-fio-gvisor-uid1000.log` | gVisor EFS fio uid=1000 执行日志 |
| `test-ebs-fio.log` | EBS fio 执行日志 |
