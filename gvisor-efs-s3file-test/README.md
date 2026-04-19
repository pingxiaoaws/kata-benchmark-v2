# gVisor + S3 Files I/O 测试

## 测试目标

测试 gVisor 运行时在 EKS 上通过 EFS CSI Driver (v3.0+) 挂载 Amazon S3 Files 的：
1. **可用性**：gVisor sandbox 是否能成功 mount S3 Files (NFS4) 并读写
2. **性能表现**：对比 runc 基线，量化 gVisor 在 S3 Files 上的 I/O 吞吐和延迟

## 背景

Amazon S3 Files 是一种共享文件系统，通过 NFS4 协议将 S3 bucket 数据以文件形式暴露。EFS CSI Driver v3.0+ 支持 S3 Files CSI 集成，volumeHandle 格式为 `s3files:[FileSystemId]`。

gVisor 的 DirectFS 模式对 NFS4 有已知兼容性问题（参见 `gvisor-efs-test/` 的 EFS 测试结论），S3 Files 同样走 NFS4，需验证是否有相同或不同的限制。

## 环境

| 项目 | 值 |
|------|-----|
| 集群 | test-s4, EKS 1.34, us-west-2 |
| 节点 | ip-172-31-9-46.us-west-2.compute.internal |
| 实例类型 | m7g.2xlarge (Graviton, arm64, 8 vCPU, 32 GiB) |
| gVisor 版本 | release-20260406.0 (DirectFS 默认启用) |
| EFS CSI Driver | v3.0+ (支持 S3 Files) |
| S3 Files | 待创建 (需要 S3 bucket + s3files file system) |
| fio 版本 | 3.28 |
| fio 参数 | ioengine=psync, iodepth=32, numjobs=4, runtime=60s, size=1G |

## 前置条件

### 1. IAM 配置

EFS CSI Driver 需要额外的 S3 Files 权限：

- **Controller SA** (`efs-csi-controller-sa`): 需要 `AmazonS3FilesCSIDriverPolicy`
- **Node SA** (`efs-csi-node-sa`): 需要 `AmazonS3ReadOnlyAccess` + `AmazonElasticFileSystemsUtils`

如果已有 EFS 的 Pod Identity 配置，需额外 attach S3 Files 相关 policy。

### 2. 创建 S3 Files 文件系统

参考 `manifests/setup-s3files.sh`

### 3. EFS CSI Driver 版本

确认 EFS CSI Driver >= 3.0.0：
```bash
kubectl get pods -n kube-system -l app=efs-csi-controller -o jsonpath='{.items[0].spec.containers[?(@.name=="efs-plugin")].image}'
```

## 测试步骤

### Phase 1: 可用性验证

1. 创建 S3 Files 文件系统和 mount target（`manifests/setup-s3files.sh`）
2. 部署 Static Provisioning 的 PV/PVC（`manifests/s3files-static-pv.yaml`）
3. 分别用 runc 和 gvisor 运行 pod，验证：
   - mount 是否成功
   - 文件读写是否正常
   - 权限/uid 映射是否正确

### Phase 2: 性能基准

1. 运行 fio benchmark：`s3files-fio-benchmark.sh`
2. 测试矩阵：
   - 运行时：runc, gvisor (uid=1000)
   - 读写模式：seqread, seqwrite, randread, randwrite
   - Block size：4K, 128K, 1M

### Phase 3: 对比分析

对比 S3 Files vs EFS (NFS4) vs EBS (ext4) 在 gVisor 下的表现差异。

## 文件结构

```
gvisor-efs-s3file-test/
├── README.md                      # 本文件
├── manifests/
│   ├── setup-s3files.sh           # S3 Files 文件系统创建脚本
│   ├── s3files-storageclass.yaml  # StorageClass
│   ├── s3files-static-pv.yaml    # Static PV
│   ├── s3files-pvc.yaml          # PVC
│   ├── s3files-dynamic-sc.yaml   # Dynamic Provisioning StorageClass
│   ├── pod-runc.yaml             # runc 测试 Pod
│   ├── pod-gvisor.yaml           # gVisor 测试 Pod
│   └── pod-gvisor-uid1000.yaml   # gVisor uid=1000 测试 Pod
├── s3files-fio-benchmark.sh       # fio 性能测试脚本
├── results/                       # 测试结果（测试后生成）
└── QA.md                          # 问题与分析
```

## 已知风险

1. **NFS4 + gVisor DirectFS 兼容性**：EFS 测试中，root 用户无法写入 NFS4；uid=1000 通过 Access Point 可以写入。S3 Files 是否有相同行为需验证。
2. **S3 Files 一致性模型**：S3 Files 的文件语义与原生 NFS/EFS 可能有差异（最终一致性 vs 强一致性）。
3. **EFS CSI Driver 版本**：需要 v3.0.0+，当前集群 driver 版本需确认。
