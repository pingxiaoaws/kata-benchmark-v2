# gVisor 测试环境配置

## 概述

在 EKS 集群 test-s4 上配置 gVisor (runsc) 运行时，用于与 runc / kata-qemu / kata-clh 对比测试。

gVisor 不需要嵌套虚拟化，普通 EC2 实例即可运行。

## 架构

```
gVisor (runsc) 隔离模型：
  Application → gVisor Sentry (用户态内核) → Host Kernel
  
vs Kata Containers 隔离模型：
  Application → Guest Kernel (VM) → Host Kernel
```

## 节点配置

| 属性 | 值 |
|------|-----|
| 实例类型 | m8i.2xlarge（8 vCPU，32 GiB） |
| AMI | AL2023 EKS 1.34 optimized |
| ASG | gvisor-m8i-2xlarge-asg |
| Launch Template | gvisor-m8i-2xlarge (lt-0f8d77f6f2b22be33) |
| 节点标签 | `workload-type=gvisor`, `runtime=gvisor` |
| 节点 Taint | `gvisor=true:NoSchedule` |
| RuntimeClass | `gvisor` (handler: `runsc`) |

## 文件说明

| 文件 | 说明 |
|------|------|
| `userdata-gvisor-node.sh` | 节点启动脚本：安装 runsc + 配置 containerd + EKS bootstrap |
| `launch-template.json` | EC2 Launch Template 完整配置 |
| `asg-config.json` | Auto Scaling Group 配置 |
| `runtimeclass-gvisor.yaml` | Kubernetes RuntimeClass 定义 |

## 手动重建步骤

```bash
# 1. 创建 Launch Template
aws ec2 create-launch-template \
  --launch-template-name gvisor-m8i-2xlarge \
  --launch-template-data file://launch-template-data.json

# 2. 创建 ASG
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name gvisor-m8i-2xlarge-asg \
  --launch-template LaunchTemplateId=lt-xxx,Version='$Latest' \
  --min-size 0 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier "subnet-0ddf028eca68fffa2" \
  --tags "Key=kubernetes.io/cluster/test-s4,Value=owned,PropagateAtLaunch=true"

# 3. 创建 RuntimeClass
kubectl apply -f runtimeclass-gvisor.yaml

# 4. 缩容（测试完毕）
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name gvisor-m8i-2xlarge-asg \
  --desired-capacity 0 --region us-west-2
```
