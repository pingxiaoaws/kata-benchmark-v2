# gVisor + S3 Files Q&A

## Q1: S3 Files 和 EFS 有什么区别？

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
| IAM Policy | AmazonEFSCSIDriverPolicy | AmazonS3FilesCSIDriverPolicy |

## Q2: gVisor + S3 Files 是否有和 EFS 相同的 NFS4 兼容性问题？

**预期有相同问题**，因为 S3 Files 底层同样走 NFS4 协议：
- gVisor DirectFS 模式下，root 用户对 NFS4 mount 点的写入可能报 `Operation not permitted`
- 使用 uid=1000 + Access Point（或 S3 Files Access Point）配置 directoryPerms 可以绕过

**实际结果**：待测试验证

## Q3: S3 Files 的 Access Point 和 EFS Access Point 有什么不同？

S3 Files Access Points:
- 是应用级别的 entry point
- 可以强制 uid/gid identity
- 可以指定 root directory
- 在 Dynamic Provisioning 中通过 `provisioningMode: s3files-ap` 使用

配置方式与 EFS AP 类似，但 API 调用不同（使用 `aws s3files` 命令而非 `aws efs`）。

## Q4: S3 Files 的性能预期如何？

S3 Files 通过 NFS4 协议访问 S3 数据，性能预期：
- **顺序读**：接近 S3 吞吐（取决于实例带宽）
- **随机读**：S3 object 的 range read，延迟高于 EFS
- **写入**：写入到 S3，可能有较高延迟（对象存储写入语义）
- **小文件 IOPS**：S3 的 PUT/GET 开销，不如本地文件系统

与 EFS 对比：
- 顺序大文件读取可能更优（S3 大对象吞吐高）
- 随机小 I/O 可能更差（S3 对象存储语义开销）
- 写入一致性模型可能不同

## Q5: 如果 gVisor + S3 Files 写入失败，有哪些 workaround？

1. **uid=1000 + Access Point**：与 EFS 相同的 workaround
2. **S3 Files Access Point directoryPerms**：确保目录权限匹配 pod 用户
3. **只读挂载**：如果只需要读取训练数据，可以用 ReadOnlyMany 模式
4. **Sidecar 模式**：runc sidecar 负责写入，gVisor container 只读

## Q6: 生产环境建议？

如果 gVisor + S3 Files 可用：
- AI/ML 训练数据集：S3 Files ReadOnlyMany + gVisor（安全隔离读取）
- 共享模型文件：S3 Files + Access Point uid mapping
- 日志/checkpoint 写入：需验证写入性能是否可接受

如果 gVisor + S3 Files 写入受限：
- 读取密集型 workload 仍可使用 S3 Files（ReadOnlyMany）
- 写入密集型考虑 EBS + gVisor 或 runc + S3 Files
