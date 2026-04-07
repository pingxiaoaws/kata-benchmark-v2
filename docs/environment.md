# 测试环境详细信息

## EKS 集群

- **集群名**: test-s4
- **K8s 版本**: v1.34.4-eks-f69f56f
- **区域**: us-west-2
- **VPC**: vpc-05356dbcee07a48de
- **AWS Account**: XXXXXXXXXXXX

## 节点列表

### Benchmark 节点 (m8i.4xlarge × 9, ASG: eks-test-s4-m8i-benchmark)

| 节点 | Private IP | Taint |
|------|-----------|-------|
| node-1 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-2 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-3 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-4 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-5 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-6 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-7 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-8 | x.x.x.x | kata-benchmark=true:NoSchedule |
| node-10 | x.x.x.x | (无 taint，untainted) |

### Oversell 节点 (r8i.2xlarge × 1, ASG: eks-test-s4-r8i-oversell)

| 节点 | Private IP | Taint |
|------|-----------|-------|
| node-oversell | x.x.x.x | kata-oversell=true:NoSchedule |

### 节点公共配置

- **OS**: Amazon Linux 2023.10.20260216
- **Host Kernel**: 6.12.68-92.122.amzn2023.x86_64
- **containerd**: 2.1.5
- **AMI**: ${AMI_ID}
- **Launch Template**: lt-0dd7cfb1e76d7b01e (eks-node-m8i-nested-virt)
- **标签**: workload-type=kata
- **嵌套虚拟化**: 已启用 (Intel VMX, /dev/kvm available)

## Kata Containers

- **Kata 版本**: 3.27.0
- **RuntimeClass**: kata-qemu, kata-clh, kata-fc
- **VM Kernel**: 6.18.12

## OpenClaw Operator

- **版本**: v0.22.2
- **镜像**: ghcr.io/openclaw-rocks/openclaw-operator:v0.22.2
- **Helm Chart**: openclaw-operator 0.22.2
- **Namespace**: openclaw-operator-system

### 已知问题

1. **Operator v0.10.7 不传递 runtimeClassName** — 必须升级到 v0.22.2+
2. **containerd 2.2.1 cgroup device controller bug** — 导致 Kata 无法访问 /dev/kvm，必须用 2.1.x
3. **CRD 过大 (>262KB)** — `kubectl apply` 会失败，需用 `kubectl replace`

## StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
```
