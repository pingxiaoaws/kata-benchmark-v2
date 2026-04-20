# gVisor + S3 Files I/O 测试

## 测试目标

测试 gVisor 运行时在 EKS 上通过 EFS CSI Driver (v3.0+) 挂载 Amazon S3 Files 的：
1. **可用性**：gVisor sandbox 是否能成功 mount S3 Files (NFS4) 并读写
2. **性能表现**：对比 runc 基线，量化 gVisor 在 S3 Files 上的 I/O 吞吐和延迟

## 测试结论（TL;DR）

### 可用性

| 配置 | Static PV (无 Access Point) | Dynamic PV (有 Access Point) |
|------|---|---|
| runc (root) | ✅ 读写正常 | ✅ 读写正常 |
| gVisor (root) | ✅ 读写正常 | ❌ `Operation not permitted` |
| gVisor (uid=1000) | ✅ 读写正常 | ✅ 读写正常 |

**关键发现**：
- Static PV 无 Access Point 时，gVisor root **可以**写入 S3 Files（不同于 EFS！）
- Dynamic PV 通过 Access Point 强制 uid 映射后，行为与 EFS 完全一致
- **生产推荐**：`securityContext: runAsUser: 1000, runAsGroup: 1000` + Dynamic PV

### 性能

⚠️ **gVisor 和 runc 的 fio 数据不可直接比较**

gVisor 的 9p VFS 缓存完全吸收了 I/O（忽略 O_DIRECT、fsync），导致 gVisor 显示 3-36x 高吞吐量，实际测的是用户态内存缓存。runc 数据才反映 S3 Files 后端真实性能。

**S3 Files 后端真实性能（runc 数据，m7g.2xlarge）**：

| 模式 | 4k | 128k | 1M |
|------|-----|------|-----|
| Seq Read | 2,150 MiB/s | 3,516 MiB/s | 3,524 MiB/s |
| Seq Write | 830 MiB/s | 1,653 MiB/s | 1,529 MiB/s |
| Rand Read | 34 MiB/s (8.7K IOPS) | 681 MiB/s | — |
| Rand Write | 188 MiB/s (48K IOPS) | 1,194 MiB/s | — |

详细分析见 `ANALYSIS.md`。

## 环境

| 项目 | 值 |
|------|-----|
| 集群 | test-s4, EKS 1.34, us-west-2 |
| 节点 | ip-172-31-9-46.us-west-2.compute.internal |
| 实例类型 | m7g.2xlarge (Graviton3, arm64, 8 vCPU, 32 GiB) |
| gVisor 版本 | release-20260406.0 (DirectFS 默认启用) |
| EFS CSI Driver | v3.0.0-eksbuild.1 |
| S3 Files FS | fs-0987d9f1d827a8767 |
| S3 Bucket | gvisor-s3files-test-970547376847 |
| fio 版本 | 3.28 |
| fio 参数 | ioengine=psync, numjobs=4, runtime=60s, size=512M, fsync_on_close=1 |

## 测试步骤

### Phase 0: 环境准备

```bash
# 1. 升级 AWS CLI 到 v2.34+ (支持 aws s3files 命令)
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q -o awscliv2.zip && sudo ./aws/install --update

# 2. 升级 EFS CSI Driver 到 v3.0.0
aws eks update-addon --cluster-name test-s4 --addon-name aws-efs-csi-driver \
  --addon-version v3.0.0-eksbuild.1 --resolve-conflicts OVERWRITE --region us-west-2

# 3. 创建 S3 Files 文件系统
bash setup-s3files.sh

# 4. 附加 S3 Files CSI Policy 到 controller role
aws iam attach-role-policy --role-name AmazonEKSPodIdentityAmazonEFSCSIDriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonS3FilesCSIDriverPolicy

# 5. 创建 Node SA Pod Identity
aws eks create-pod-identity-association --cluster-name test-s4 \
  --role-arn arn:aws:iam::970547376847:role/AmazonEKS_EFS_CSI_NodeRole \
  --namespace kube-system --service-account efs-csi-node-sa --region us-west-2
```

### Phase 1: Static Provisioning 测试

详见 [`static-provisioning/README.md`](static-provisioning/README.md)

```bash
cd static-provisioning/
kubectl apply -f manifests/
bash s3files-fio-benchmark.sh
```

### Phase 2: Dynamic Provisioning 测试

详见 [`dynamic-provisioning/README.md`](dynamic-provisioning/README.md)

```bash
cd dynamic-provisioning/
kubectl apply -f manifests/s3files-dynamic-sc.yaml
kubectl apply -f manifests/s3files-dynamic-pvc.yaml
bash s3files-dynamic-test.sh
```

## 目录结构

```
gvisor-efs-s3file-test/
├── README.md                          # 本文件（总览）
├── ANALYSIS.md                        # 详细性能分析报告
├── QA.md                              # 搭建踩坑 Q&A（13 个问题）
├── setup-s3files.sh                   # S3 Files 文件系统创建脚本（共享）
│
├── static-provisioning/               # Static PV 测试（无 Access Point）
│   ├── README.md                      # 测试步骤和结论
│   ├── manifests/
│   │   ├── s3files-storageclass.yaml
│   │   ├── s3files-static-pv.yaml
│   │   ├── s3files-pvc.yaml
│   │   ├── pod-runc.yaml
│   │   ├── pod-gvisor.yaml
│   │   └── pod-gvisor-uid1000.yaml
│   ├── s3files-fio-benchmark.sh       # fio 性能测试脚本
│   └── results/
│       └── fio-results.csv            # 原始 fio 数据
│
└── dynamic-provisioning/              # Dynamic PV 测试（有 Access Point）
    ├── README.md                      # 测试步骤和结论
    ├── manifests/
    │   ├── s3files-dynamic-sc.yaml
    │   ├── s3files-dynamic-pvc.yaml
    │   ├── pod-dyn-runc.yaml
    │   ├── pod-dyn-gvisor.yaml
    │   └── pod-dyn-gvisor-uid1000.yaml
    └── s3files-dynamic-test.sh        # 可用性自动化测试脚本
```

## 与 EFS 测试的对比

| 维度 | EFS (gvisor-efs-test/) | S3 Files (本目录) |
|------|-----|----------|
| gVisor root 写入 (Static PV) | ❌ Operation not permitted | ✅ 正常 |
| gVisor root 写入 (Dynamic PV) | ❌ Operation not permitted | ❌ Operation not permitted |
| gVisor uid=1000 写入 | ✅ | ✅ |
| gVisor VFS 缓存效应 | ✅ 存在 | ✅ 存在 |
| 底层协议 | NFS4 | NFS4 |
| CSI Driver | efs.csi.aws.com v2.x+ | efs.csi.aws.com v3.0+ |
| 数据存储 | EFS 服务 | S3 bucket |

## 已创建 AWS 资源

| 资源 | 标识 |
|------|------|
| S3 Bucket | gvisor-s3files-test-970547376847 |
| S3 Files FileSystem | fs-0987d9f1d827a8767 |
| IAM Role (S3 Files → S3) | S3FilesAccessRole-gvisor-test |
| IAM Role (EFS CSI Node) | AmazonEKS_EFS_CSI_NodeRole |
| Security Group | sg-0332a867b8b69d9f2 (gvisor-s3files-sg) |
| Pod Identity (node) | a-krf6enxqs51qz3abs |

## 测试日期

2026-04-19
