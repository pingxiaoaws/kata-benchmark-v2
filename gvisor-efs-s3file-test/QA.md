# gVisor + S3 Files Q&A

## 基础概念

### Q1: S3 Files 和 EFS 有什么区别？

**S3 Files** 是一种共享文件系统，将 S3 bucket 中的数据通过 NFS4 协议以文件系统形式暴露：
- 数据存储在 S3 bucket 中（不离开 S3）
- 通过 NFS4 mount 访问
- 适合 AI/ML 训练数据、共享数据集等场景
- 使用 EFS CSI Driver v3.0+ 集成 Kubernetes

**EFS** 是独立的 NFS4 文件系统：
- 数据存储在 EFS 服务中
- 同样通过 NFS4 mount 访问
- 适合共享配置、日志、通用文件存储

两者在 CSI 层面的关键差异：
| 项目 | EFS | S3 Files |
|------|-----|----------|
| volumeHandle | `fs-xxx` | `s3files:fs-xxx` |
| CSI Driver | efs.csi.aws.com | efs.csi.aws.com (v3.0+) |
| 底层协议 | NFS4 | NFS4 |
| 数据存储 | EFS 服务 | S3 bucket |
| Dynamic Provisioning | efs-ap | s3files-ap |
| IAM Policy (Controller) | AmazonEFSCSIDriverPolicy | AmazonS3FilesCSIDriverPolicy |
| IAM Policy (Node) | 无 | AmazonS3ReadOnlyAccess + AmazonElasticFileSystemsUtils |

### Q2: gVisor + S3 Files 是否有和 EFS 相同的 NFS4 兼容性问题？

**预期有相同问题**，因为 S3 Files 底层同样走 NFS4 协议：
- gVisor DirectFS 模式下，root 用户对 NFS4 mount 点的写入可能报 `Operation not permitted`
- 使用 uid=1000 + Access Point（或 S3 Files Access Point）配置 directoryPerms 可以绕过

**实际结果**：

| 配置 | Static PV (无 Access Point) | Dynamic PV (有 Access Point, uid=1000) |
|------|---|---|
| runc (root) | ✅ 读写正常 | ✅ 读写正常（文件 owner 被 AP 映射为 1000:1000）|
| gVisor (root) | ✅ 读写正常 | ❌ `Operation not permitted`（和 EFS 一样）|
| gVisor (uid=1000) | 未测 | ✅ 读写正常 |

**关键发现**：
- Static PV 无 Access Point 时，gVisor root 可以直接读写 S3 Files（不同于 EFS！）
- Dynamic PV 通过 `provisioningMode: s3files-ap` 创建 Access Point 后，行为与 EFS 完全一致
- Access Point 是触发 root squash 的原因，不是 S3 Files 本身

---

## 搭建过程踩坑

### Q3: S3 Files IAM Role 的 Trust Policy 怎么配？

**问题**：文档示例用 `s3files.amazonaws.com` 作为 service principal，但 IAM 不接受这个 principal（`Invalid principal in policy`）。

**解决**：需要同时信任 `s3.amazonaws.com` 和 `elasticfilesystem.amazonaws.com`：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "s3.amazonaws.com",
          "elasticfilesystem.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**原因**：S3 Files 是一个较新的服务，其 service principal 在当前 IAM 全局端点中尚未注册。实际的 AssumeRole 可能走 `s3.amazonaws.com`。

### Q4: S3 Files create-file-system 报 "Access denied: S3 Files does not have permissions to assume the provided role"

**原因**：初始 trust policy 只信任了 `s3.amazonaws.com`，但 S3 Files 服务需要能 AssumeRole。加上 `elasticfilesystem.amazonaws.com` 后解决。

**完整修复步骤**：
```bash
aws iam update-assume-role-policy \
  --role-name S3FilesAccessRole-gvisor-test \
  --policy-document file://trust-policy.json
```

### Q5: S3 Files create-file-system 报 "role does not have permission to call s3:HeadObject"

**原因**：给 IAM Role 的 inline policy 只列出了部分 S3 actions（GetObject, PutObject, DeleteObject, ListBucket, GetBucketLocation），缺少 `s3:HeadObject`。

**解决**：直接给 `s3:*` 权限到目标 bucket（测试环境可以放开，生产环境需最小权限）：

```json
{
  "Effect": "Allow",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::BUCKET_NAME",
    "arn:aws:s3:::BUCKET_NAME/*"
  ]
}
```

### Q6: S3 bucket 需要开启 Versioning

**问题**：`create-file-system` 报错 `Your bucket must have versioning enabled to create a file system.`

**解决**：
```bash
aws s3api put-bucket-versioning \
  --bucket BUCKET_NAME \
  --versioning-configuration Status=Enabled
```

这是 S3 Files 的硬性要求 — 需要 S3 版本控制来维护文件系统语义。

### Q7: AWS CLI 版本需要升级才能使用 `aws s3files` 命令

**问题**：AWS CLI v2.17.18 没有 `s3files` 子命令（S3 Files 是 2026 年新服务）。

**解决**：升级到 v2.34.32+：
```bash
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
cd /tmp && unzip -q -o awscliv2.zip
sudo ./aws/install --update
```

### Q8: EFS CSI Driver 需要升级到 v3.0.0

**问题**：S3 Files CSI 支持从 EFS CSI Driver v3.0.0 开始。我们集群原有 v2.3.0。

**升级命令**：
```bash
aws eks update-addon \
  --cluster-name test-s4 \
  --addon-name aws-efs-csi-driver \
  --addon-version v3.0.0-eksbuild.1 \
  --resolve-conflicts OVERWRITE \
  --region us-west-2
```

**注意**：升级后需要额外创建 `efs-csi-node-sa` 的 Pod Identity association（v2 只有 controller-sa 的关联）。

### Q9: S3 Files Mount Target 创建速度很慢

**观察**：EFS mount target 通常 1-2 分钟创建完成，S3 Files mount target 创建时间明显更长（>3 分钟），可能因为底层需要建立 S3 → NFS 的转换通道。

**建议**：创建后耐心等待，可用 polling 检查状态：
```bash
aws s3files list-mount-targets --file-system-id fs-xxx --region us-west-2 \
  --query 'mountTargets[*].[status,ipv4Address]' --output table
```

---

## S3 Files 技术细节

### Q10: S3 Files 的 Access Point 和 EFS Access Point 有什么不同？

S3 Files Access Points:
- 是应用级别的 entry point
- 可以强制 uid/gid identity
- 可以指定 root directory
- 在 Dynamic Provisioning 中通过 `provisioningMode: s3files-ap` 使用
- API: `aws s3files create-access-point`

配置方式与 EFS AP 类似，但 API 使用 `aws s3files`（非 `aws efs`）。

### Q11: S3 Files 的性能预期如何？

S3 Files 通过 NFS4 协议访问 S3 数据，性能预期：
- **顺序读**：接近 S3 吞吐（取决于实例带宽）
- **随机读**：S3 object 的 range read，延迟可能高于 EFS
- **写入**：写入到 S3，可能有较高延迟（对象存储写入语义）
- **小文件 IOPS**：S3 的 PUT/GET 开销，不如本地文件系统

与 EFS 对比：
- 顺序大文件读取可能更优（S3 大对象吞吐高）
- 随机小 I/O 可能更差（S3 对象存储语义开销）
- 写入一致性模型可能不同

---

## 生产建议

### Q12: 如果 gVisor + S3 Files 写入失败，有哪些 workaround？

1. **uid=1000 + Access Point**：与 EFS 相同的 workaround
2. **S3 Files Access Point directoryPerms**：确保目录权限匹配 pod 用户
3. **只读挂载**：如果只需要读取训练数据，可以用 ReadOnlyMany 模式
4. **Sidecar 模式**：runc sidecar 负责写入，gVisor container 只读

### Q13: 生产环境建议？

如果 gVisor + S3 Files 可用：
- AI/ML 训练数据集：S3 Files ReadOnlyMany + gVisor（安全隔离读取）
- 共享模型文件：S3 Files + Access Point uid mapping
- 日志/checkpoint 写入：需验证写入性能是否可接受

如果 gVisor + S3 Files 写入受限：
- 读取密集型 workload 仍可使用 S3 Files（ReadOnlyMany）
- 写入密集型考虑 EBS + gVisor 或 runc + S3 Files

---

## 环境信息

| 项目 | 值 |
|------|-----|
| S3 Bucket | gvisor-s3files-test-970547376847 |
| S3 Files FileSystem ID | fs-0987d9f1d827a8767 |
| IAM Role (S3 Files → S3) | S3FilesAccessRole-gvisor-test |
| IAM Role (EFS CSI Controller) | AmazonEKSPodIdentityAmazonEFSCSIDriverRole |
| IAM Role (EFS CSI Node) | AmazonEKS_EFS_CSI_NodeRole |
| Security Group | sg-0332a867b8b69d9f2 |
| EFS CSI Driver | v3.0.0-eksbuild.1 |
| AWS CLI | v2.34.32 |
