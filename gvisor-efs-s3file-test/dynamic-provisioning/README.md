# S3 Files Dynamic Provisioning 测试

## 概述

Dynamic Provisioning 通过 `provisioningMode: s3files-ap` 自动创建 S3 Files Access Point，强制 uid/gid 映射。验证 gVisor 在 Access Point 约束下的 NFS4 读写行为。

## 可用性结论

| 配置 | 读 | 写 | 说明 |
|------|-----|-----|------|
| runc (root) | ✅ | ✅ | 文件 owner 被 AP 映射为 1000:1000 |
| gVisor (root) | ✅ | ❌ `Operation not permitted` | 和 EFS Dynamic PV 行为一致 |
| gVisor (uid=1000) | ✅ | ✅ | **生产推荐配置** |

**关键发现**：
- Access Point 强制 uid 映射后，gVisor root 写入失败 — 和 EFS 完全一致
- 根因：gVisor DirectFS gofer 以 root 打开 NFS4 文件，但 AP 将 root 映射为 uid=1000，权限检查不一致
- **解决方案**：`securityContext: runAsUser: 1000, runAsGroup: 1000`

## 测试步骤

### 1. 前置条件

- 已运行 `../setup-s3files.sh` 创建 S3 Files 文件系统
- EFS CSI Driver >= v3.0.0
- Controller SA 已附加 `AmazonS3FilesCSIDriverPolicy`

### 2. 部署存储资源

```bash
kubectl apply -f manifests/s3files-dynamic-sc.yaml
kubectl apply -f manifests/s3files-dynamic-pvc.yaml

# 确认 PVC Bound（Dynamic PV 自动创建）
kubectl get pvc s3files-dynamic-pvc
# STATUS: Bound
```

StorageClass 参数说明：
```yaml
parameters:
  provisioningMode: s3files-ap    # 使用 S3 Files Access Point
  fileSystemId: "fs-0987d9f1d827a8767"
  directoryPerms: "700"           # AP 根目录权限
  uid: "1000"                     # AP 强制 uid
  gid: "1000"                     # AP 强制 gid
  basePath: "/dynamic"            # AP 子目录基路径
```

### 3. 部署测试 Pod

```bash
# 三种配置同时部署
kubectl apply -f manifests/pod-dyn-runc.yaml
kubectl apply -f manifests/pod-dyn-gvisor.yaml
kubectl apply -f manifests/pod-dyn-gvisor-uid1000.yaml

# 等待就绪
kubectl wait pod/s3files-dyn-runc --for=condition=Ready --timeout=180s
kubectl wait pod/s3files-dyn-gvisor --for=condition=Ready --timeout=180s
kubectl wait pod/s3files-dyn-gvisor-uid1000 --for=condition=Ready --timeout=180s
```

### 4. 可用性验证

```bash
# Test 1: runc (root) — 预期成功，文件 owner 为 1000:1000
kubectl exec s3files-dyn-runc -- bash -c "id && echo test > /data/test.txt && ls -la /data/"
# uid=0(root) ... 
# -rw-r--r--. 1 1000 1000 ... test.txt  ← AP 强制映射

# Test 2: gVisor (root) — 预期失败
kubectl exec s3files-dyn-gvisor -- bash -c "echo test > /data/test.txt"
# bash: /data/test.txt: Operation not permitted  ← 预期行为

# Test 2b: gVisor (root) 读取 — 预期成功
kubectl exec s3files-dyn-gvisor -- bash -c "cat /data/test.txt"
# test  ← 读取 OK

# Test 3: gVisor (uid=1000) — 预期成功
kubectl exec s3files-dyn-gvisor-uid1000 -c fio -- bash -c "id && echo test > /data/test.txt && cat /data/test.txt"
# uid=1000 ...
# test  ← 写入成功
```

或使用自动化脚本：
```bash
bash s3files-dynamic-test.sh
```

### 5. 清理

```bash
kubectl delete pod s3files-dyn-runc s3files-dyn-gvisor s3files-dyn-gvisor-uid1000 --force --grace-period=0
kubectl delete pvc s3files-dynamic-pvc
kubectl delete sc s3files-dynamic-sc
```

## 生产配置模板

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: s3files-gvisor-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: s3files-ap
  fileSystemId: "fs-YOUR_FILESYSTEM_ID"
  directoryPerms: "700"
  uid: "1000"
  gid: "1000"
  basePath: "/workloads"
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
apiVersion: v1
kind: Pod
metadata:
  name: my-gvisor-app
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsUser: 1000      # 必须匹配 SC 的 uid
    runAsGroup: 1000     # 必须匹配 SC 的 gid
  containers:
  - name: app
    image: my-app:latest
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-s3files-pvc
```

## 与 Static Provisioning 的对比

| 维度 | Static PV | Dynamic PV (AP) |
|------|-----------|-----------------|
| Access Point | 无 | 自动创建 |
| uid 映射 | 无（保持原始） | 强制映射为 SC 配置的 uid |
| gVisor root 写入 | ✅ | ❌ |
| gVisor uid=1000 写入 | — | ✅ |
| 适用场景 | 简单共享、管理员直接控制 | 多租户、自动化、生产环境 |
| 隔离性 | 低（共享整个 FS） | 高（每个 PVC 独立子目录） |

## 文件说明

```
dynamic-provisioning/
├── README.md                              # 本文件
├── manifests/
│   ├── s3files-dynamic-sc.yaml            # StorageClass (s3files-ap mode)
│   ├── s3files-dynamic-pvc.yaml           # PVC (10Gi, RWX)
│   ├── pod-dyn-runc.yaml                  # runc test pod
│   ├── pod-dyn-gvisor.yaml                # gVisor (root) test pod
│   └── pod-dyn-gvisor-uid1000.yaml        # gVisor (uid=1000) test pod
└── s3files-dynamic-test.sh                # 自动化可用性测试脚本
```
