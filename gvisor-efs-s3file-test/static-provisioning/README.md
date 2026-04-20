# S3 Files Static Provisioning 测试

## 概述

Static Provisioning 直接挂载整个 S3 Files 文件系统（无 Access Point），验证 gVisor 在无 uid 映射约束下的 NFS4 I/O 能力。

## 可用性结论

| 配置 | 读 | 写 |
|------|-----|-----|
| runc (root) | ✅ | ✅ |
| gVisor (root) | ✅ | ✅ |
| gVisor (uid=1000) | ✅ | ✅ |

**关键发现**：Static PV 无 Access Point 时，gVisor root **可以**直接写入 S3 Files，不同于 EFS 的表现。

## 测试步骤

### 1. 前置条件

确保已运行 `../setup-s3files.sh` 创建 S3 Files 文件系统和 mount targets。

### 2. 部署存储资源

```bash
kubectl apply -f manifests/s3files-storageclass.yaml
kubectl apply -f manifests/s3files-static-pv.yaml
kubectl apply -f manifests/s3files-pvc.yaml

# 确认 PVC Bound
kubectl get pvc s3files-fio
```

### 3. 部署测试 Pod

```bash
kubectl apply -f manifests/pod-runc.yaml       # runc (root)
kubectl apply -f manifests/pod-gvisor.yaml      # gVisor (root)

# 等待就绪
kubectl wait pod/s3files-fio-runc --for=condition=Ready --timeout=180s
kubectl wait pod/s3files-fio-gvisor --for=condition=Ready --timeout=180s
```

### 4. 可用性验证

```bash
# runc 写入
kubectl exec s3files-fio-runc -- bash -c "echo 'hello' > /data/test.txt && cat /data/test.txt"

# gVisor root 写入（预期成功）
kubectl exec s3files-fio-gvisor -- bash -c "echo 'hello' > /data/test.txt && cat /data/test.txt"

# 查看 mount 信息
kubectl exec s3files-fio-runc -- mount | grep /data
# 输出: 127.0.0.1:/ on /data type nfs4 (rw,...)

kubectl exec s3files-fio-gvisor -- cat /proc/mounts | grep /data
# 输出: none /data 9p rw,...,directfs ...
```

### 5. 运行 fio 性能测试

```bash
# 等待 fio 安装完成（约 40s）
sleep 40

# 使用自动化脚本
bash s3files-fio-benchmark.sh

# 或手动单项测试
kubectl exec s3files-fio-runc -- fio --name=test --filename=/data/testfile \
  --size=512M --rw=read --bs=128k --ioengine=psync --numjobs=4 \
  --runtime=60 --time_based --group_reporting --output-format=json
```

### 6. 清理

```bash
kubectl delete pod s3files-fio-runc s3files-fio-gvisor --force --grace-period=0
kubectl delete pvc s3files-fio
kubectl delete pv s3files-pv
kubectl delete sc s3files-sc
```

## 性能结果

详见 `results/fio-results.csv` 和 `../ANALYSIS.md`

**⚠️ 重要说明**：gVisor 吞吐量比 runc 高 3-36 倍是 VFS 缓存假象（9p cache 吸收了所有 I/O，O_DIRECT 被忽略）。runc 数据才反映 S3 Files 后端真实性能。

**S3 Files 后端真实性能（runc 数据，m7g.2xlarge）：**

| 模式 | 4k | 128k | 1M |
|------|-----|------|-----|
| Seq Read | 2,150 MiB/s | 3,516 MiB/s | 3,524 MiB/s |
| Seq Write | 830 MiB/s | 1,653 MiB/s | 1,529 MiB/s |
| Rand Read | 34 MiB/s | 681 MiB/s | — |
| Rand Write | 188 MiB/s | 1,194 MiB/s | — |

## 文件说明

```
static-provisioning/
├── README.md                          # 本文件
├── manifests/
│   ├── s3files-storageclass.yaml      # StorageClass (provisioner: efs.csi.aws.com)
│   ├── s3files-static-pv.yaml        # PV (volumeHandle: s3files:fs-0987d9f1d827a8767)
│   ├── s3files-pvc.yaml              # PVC (100Gi, RWX)
│   ├── pod-runc.yaml                 # runc test pod
│   ├── pod-gvisor.yaml               # gVisor (root) test pod
│   └── pod-gvisor-uid1000.yaml       # gVisor (uid=1000) test pod
├── s3files-fio-benchmark.sh           # 自动化 fio benchmark 脚本
└── results/
    └── fio-results.csv                # fio 原始结果
```
