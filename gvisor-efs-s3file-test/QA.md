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

## EFS 文件系统基础

### Q14: EFS 的"文件系统"(File System) 到底是什么？

EFS FileSystem (`fs-xxx`) 是一个**网络共享文件系统**，可以类比为：

| 概念 | Windows 类比 | Linux 类比 |
|------|-------------|-----------|
| EFS FileSystem | 网络共享 `\\server\share` | NFS export |
| Mount Target | 网络路径/IP | NFS server IP |
| 挂载到本地 | 映射为 `Z:` 盘 | `mount -t nfs4 ... /mnt/data` |

挂载后就像本地目录一样使用：
```bash
# Linux EC2
sudo mount -t nfs4 fs-xxx.efs.us-west-2.amazonaws.com:/ /mnt/efs
ls /mnt/efs
echo "hello" > /mnt/efs/test.txt
```

与本地盘 (EBS) 的区别：
- **EBS**：单机独占，低延迟 (<1ms)
- **EFS**：多机共享 (ReadWriteMany)，延迟较高 (~3-5ms)，自动扩缩容，数据持久化

### Q15: Mount Target 是什么？跨子网/跨 AZ 能用吗？

Mount Target 是一个**网络端点 (ENI)**，部署在 VPC 的某个子网中，提供 NFS 服务 IP 地址。

**网络可达性**：
- **同 VPC 内所有子网都能路由到**（VPC 内部 local route），不限于同一子网
- **同 AZ 访问**：延迟 <1ms，**免费**
- **跨 AZ 访问**：延迟 +0.5-1ms，**收跨 AZ 流量费**（$0.01/GB 双向）

**最佳实践**：每个 AZ 各放一个 Mount Target，EFS CSI driver 通过 DNS 自动解析到当前 AZ 的 Mount Target。

**子网与 AZ 的关系**：一个子网只属于一个 AZ，但一个 AZ 可以有多个子网。每个 AZ 只需要一个 Mount Target，放在该 AZ 的任意子网即可。

### Q16: 使用 EFS/S3Files 必须提前创建文件系统吗？CSI 的"动态 provisioning"动态的是什么？

**文件系统必须提前创建**，CSI driver 不会帮你创建。动态 provisioning 的"动态"指的是 **Access Point**：

```
你手动创建（一次性）             CSI driver 动态创建（每个 PVC）
─────────────────             ──────────────────────────
FileSystem (fs-xxx)        →  Access Point (fsap-aaa) → PVC-1
  + Mount Target(s)        →  Access Point (fsap-bbb) → PVC-2
  + StorageClass           →  Access Point (fsap-ccc) → PVC-3
```

| 资源 | 谁创建 | 频率 |
|------|--------|------|
| FileSystem | 运维手动 / IaC | 一次 |
| Mount Target | 运维手动 / IaC | 每个 AZ 一次 |
| StorageClass | 运维手动 `kubectl apply` | 一次 |
| Access Point | **CSI driver 自动** | 每个 PVC 自动创建 |
| PV | **CSI driver 自动** | 每个 PVC 自动创建 |

### Q17: Access Point 的本质是什么？

Access Point = **文件系统里的子目录入口** + **强制权限绑定**：

```
EFS FileSystem (fs-xxx) 根目录 /
├── /dynamic/                          ← basePath (StorageClass 配置)
│   ├── /dynamic/pvc-aaa/              ← Access Point 1 → PVC-1 看到的根
│   ├── /dynamic/pvc-bbb/              ← Access Point 2 → PVC-2 看到的根
│   └── /dynamic/pvc-ccc/              ← Access Point 3 → PVC-3 看到的根
```

Access Point 的三个核心属性：
| 属性 | 作用 |
|------|------|
| **Root Directory** | chroot 到指定路径（如 `/dynamic/pvc-xxx`） |
| **POSIX User** | 强制所有访问以 uid/gid 身份执行 |
| **目录自动创建** | 路径不存在时自动创建并设好 owner/permissions |

简单理解：**Access Point = chroot 到子目录 + 强制 uid**。每个 PVC 得到隔离的子目录，互相看不到。

---

## EFS/S3Files 安全性

### Q18: 在 runc 下 root Pod 能访问 Access Point 设了 uid=1000 的 EFS 目录吗？gVisor 呢？

| 运行时 | Pod UID | Access Point uid=1000 | 结果 | 原因 |
|--------|---------|----------------------|------|------|
| runc | root (0) | ✅ 读写正常 | NFS 服务端 Access Point 强制映射为 uid=1000 |
| gVisor | root (0) | ❌ Operation not permitted | gVisor 9p VFS 在用户态做 DAC 检查，不像真实内核对 root 跳过 |
| gVisor | 1000 | ✅ 读写正常 | uid 匹配 |

**生产建议**：gVisor 必须 `securityContext.runAsUser: 1000` 匹配 Access Point 的 uid。

### Q19: 随便一个 Pod 都能挂载 EFS 吗？默认安全性如何？

**默认配置下安全性确实不强**。不加任何控制的 EFS ≈ VPC 内的公共网盘。

安全控制分四层：

| 层 | 控制方式 | 作用 |
|----|---------|------|
| **K8s RBAC** | Namespace + RBAC | 控制谁能创建 PVC 引用特定 StorageClass |
| **网络层** | Security Group | Mount Target SG 只放行特定来源的 2049 端口 |
| **EFS 资源策略** | FileSystem Policy | 限制只允许特定 IAM Role mount，强制加密传输，强制使用 Access Point |
| **IAM** | CSI driver 的 Role | 节点的 IAM role 不对或 Access Point 不在允许列表里，mount 被服务端拒绝 |

**FileSystem Policy 示例**（生产必配）：
```json
{
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::xxx:role/EFSCSIRole"},
  "Action": ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"],
  "Condition": {
    "StringEquals": {
      "elasticfilesystem:AccessPointArn": "arn:aws:elasticfilesystem:...:access-point/fsap-xxx"
    },
    "Bool": {
      "aws:SecureTransport": "true"
    }
  }
}
```

**生产最佳实践**：
1. FileSystem Policy — 限 IAM role + 强制 Access Point + 强制 TLS
2. Security Group — 限来源 CIDR/SG
3. K8s RBAC + namespace 隔离
4. Access Point — 每个 PVC 隔离子目录

---

## 验证 gVisor 运行时

### Q20: 如何验证 Pod 确实在 gVisor 运行时下运行？

**从 Pod 内部验证（最简单）：**
```bash
# gVisor 报告固定内核版本 4.4.0，runc 会显示宿主机内核 (如 6.12.x)
kubectl exec -n gvisor-test gvisor-efs-test -- uname -r
# → 4.4.0   ← gVisor

# /proc/version 包含 gVisor 固定时间戳
kubectl exec -n gvisor-test gvisor-efs-test -- cat /proc/version
# → Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016

# K8s Pod spec 确认 runtimeClassName
kubectl get pod -n gvisor-test gvisor-efs-test -o jsonpath='{.spec.runtimeClassName}'
# → gvisor
```

**从 EC2 宿主机验证（需要 sudo）：**
```bash
# 列出运行中的 gVisor sandbox
sudo runsc --root /run/containerd/runsc/k8s.io list

# 查看 gVisor 进程树
ps aux | grep runsc
# containerd-shim-runsc-v1  ← shim
# runsc-gofer               ← 文件系统代理 (lisafs)
# runsc-sandbox             ← Sentry (用户态内核)
# runsc wait                ← 等待退出

# 确认 containerd 配置了 runsc handler
grep -A2 runsc /etc/containerd/config.toml

# 查看 runsc 版本
/usr/local/bin/runsc --version
```

**注意**：宿主机上用 `runsc list` 必须 **sudo**，非 root 用户看不到 sandbox 信息。

---

## S3 Files 文件系统管理

### Q21: S3 Files 文件系统在哪里找？为什么 EFS 控制台看不到？

S3 Files FileSystem (`fs-xxx`) **不是 EFS**，是独立的 **Amazon S3 Files** 服务资源。在 EFS 控制台找不到是正常的。

**CLI 查看：**
```bash
# 列出所有 S3 Files 文件系统
aws s3files list-file-systems --region us-west-2

# 查看详情
aws s3files list-mount-targets --file-system-id fs-xxx --region us-west-2
```

**控制台查看：**
- S3 控制台 → 左侧导航栏 → "S3 Files" 或 "File access points"
- 直接访问：`https://us-west-2.console.aws.amazon.com/s3files/home?region=us-west-2`

**VolumeHandle 格式解读：**
```
s3files:fs-0987d9f1d827a8767::fsap-0a5c000670a36f58f
│       │                      │
│       │                      └─ S3 Files Access Point ID
│       └─ S3 Files FileSystem ID (不是 EFS!)
└─ 前缀标识：这是 S3 Files 类型
```

虽然 CSI driver 是 `efs.csi.aws.com`，但 `s3files:` 前缀告诉 driver 使用 S3 Files 模式，底层对接的是 S3 Files 服务。

### Q22: 如何创建 S3 Files FileSystem 和 Mount Target？

**前置条件：**
1. AWS CLI v2.34+（`aws s3files` 命令支持）
2. EFS CSI Driver v3.0.0+
3. S3 bucket 开启 Versioning
4. IAM Role（trust: `s3.amazonaws.com` + `elasticfilesystem.amazonaws.com`）

**创建步骤：**
```bash
# 1. 创建 S3 Files FileSystem
aws s3files create-file-system \
  --bucket "arn:aws:s3:::BUCKET_NAME" \
  --role-arn "arn:aws:iam::ACCOUNT:role/S3FilesAccessRole" \
  --region us-west-2

# 2. 为每个 AZ 创建 Mount Target
aws s3files create-mount-target \
  --file-system-id fs-xxx \
  --subnet-id subnet-xxx \
  --security-groups sg-xxx \
  --region us-west-2

# 3. 创建 StorageClass (Dynamic Provisioning)
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: s3files-dynamic-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: s3files-ap
  fileSystemId: fs-xxx
  directoryPerms: "700"
  basePath: /dynamic
  uid: "1000"
  gid: "1000"
EOF

# 4. 附加 IAM Policy 到 CSI driver roles
aws iam attach-role-policy --role-name EFS_CSI_CONTROLLER_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonS3FilesCSIDriverPolicy

# 5. 创建 Node SA Pod Identity (v3.0 新增要求)
aws eks create-pod-identity-association --cluster-name CLUSTER \
  --role-arn arn:aws:iam::ACCOUNT:role/EFS_CSI_NODE_ROLE \
  --namespace kube-system --service-account efs-csi-node-sa
```

完整自动化脚本见 `setup-s3files.sh`。

### Q23: Karpenter 动态节点如何自动挂载 EFS/S3Files？

**不需要特殊处理**。流程是 Pod 先调度到节点，kubelet 再触发 CSI mount：

```
1. Pod 创建 → Karpenter 拉起新节点
2. 节点 Ready → kubelet 处理 Pod
3. kubelet 调用 EFS CSI driver (NodePublishVolume)
4. CSI driver 执行 NFS mount → 连接 Mount Target
5. Mount 成功 → 容器启动
```

Mount Target 是网络端点 (ENI)，不是绑在某个节点上的。VPC 内任何 EC2 都能通过网络访问同 AZ（或跨 AZ）的 Mount Target。

**唯一前提**：Karpenter 新节点所在的 AZ 有 Mount Target（否则会跨 AZ 访问，增加延迟和流量费用）。`setup-s3files.sh` 脚本已为 VPC 内所有子网创建了 Mount Target。

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
