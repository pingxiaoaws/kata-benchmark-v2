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
| gVisor (uid=1000) | — | ✅ 读写正常 |

**关键发现**：
- Static PV 无 Access Point 时，gVisor root **可以**写入 S3 Files（不同于 EFS！）
- Dynamic PV 通过 Access Point 强制 uid 映射后，行为与 EFS 完全一致
- **生产推荐**：`securityContext: runAsUser: 1000, runAsGroup: 1000` + Dynamic PV

### 性能

⚠️ **gVisor 和 runc 的 fio 数据不可直接比较**

gVisor 的 9p VFS 缓存完全吸收了 I/O 请求（忽略 O_DIRECT、fsync），导致：
- gVisor 显示 3-36x 高于 runc 的吞吐量，实际测的是 gVisor 用户态内存缓存速度
- runc 数据才反映 S3 Files 后端真实性能

**S3 Files 后端真实性能（runc 数据）**：

| 模式 | 4k | 128k | 1M |
|------|-----|------|-----|
| Seq Read | 2,150 MiB/s | 3,516 MiB/s | 3,524 MiB/s |
| Seq Write | 830 MiB/s | 1,653 MiB/s | 1,529 MiB/s |
| Rand Read | 34 MiB/s (8.7K IOPS) | 681 MiB/s | — |
| Rand Write | 188 MiB/s (48K IOPS) | 1,194 MiB/s | — |

详细分析见 `results/ANALYSIS.md`。

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

1. **升级 AWS CLI** 到 v2.34+ 以支持 `aws s3files` 命令
2. **升级 EFS CSI Driver** 从 v2.3.0 到 v3.0.0-eksbuild.1
3. **创建 S3 bucket** 并开启 versioning（S3 Files 硬性要求）
4. **创建 S3 Files IAM Role**（trust: s3.amazonaws.com + elasticfilesystem.amazonaws.com）
5. **创建 S3 Files 文件系统** + 4 个 AZ 的 mount target
6. **创建 Node SA Pod Identity**（efs-csi-node-sa → AmazonEKS_EFS_CSI_NodeRole）
7. **附加 AmazonS3FilesCSIDriverPolicy** 到 controller role

### Phase 1: 可用性验证

1. 部署 Static PV/PVC 和 Dynamic StorageClass
2. 分别用 runc (root)、gVisor (root)、gVisor (uid=1000) 验证读写
3. 结论：见上方测试结论表格

### Phase 2: fio 性能基准

测试矩阵：
- **运行时**：runc, gVisor (root, static PV), gVisor (uid=1000, dynamic PV with AP)
- **读写模式**：read, write, randread, randwrite
- **Block Size**：4k, 128k, 1M (顺序) / 4k, 128k (随机)

### Phase 3: 分析

详见 `results/ANALYSIS.md`

## 文件结构

```
gvisor-efs-s3file-test/
├── README.md                      # 本文件
├── QA.md                          # 搭建过程踩坑 + 技术问答
├── manifests/
│   ├── setup-s3files.sh           # S3 Files 文件系统创建脚本
│   ├── s3files-storageclass.yaml  # Static StorageClass
│   ├── s3files-static-pv.yaml    # Static PV (volumeHandle: s3files:fs-xxx)
│   ├── s3files-pvc.yaml          # Static PVC
│   ├── s3files-dynamic-sc.yaml   # Dynamic Provisioning StorageClass (s3files-ap)
│   ├── pod-runc.yaml             # runc 测试 Pod
│   ├── pod-gvisor.yaml           # gVisor 测试 Pod
│   └── pod-gvisor-uid1000.yaml   # gVisor uid=1000 测试 Pod
├── s3files-fio-benchmark.sh       # fio 性能测试脚本
└── results/
    ├── fio-results.csv            # 原始 fio 数据
    └── ANALYSIS.md                # 详细分析报告
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
