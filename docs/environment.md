# 测试环境详细信息

## EKS 集群

- **集群名**: test-s4
- **K8s 版本**: v1.34.4-eks-f69f56f
- **区域**: us-west-2
- **VPC**: vpc-05356dbcee07a48de
- **AWS Account**: 970547376847

## 节点列表

### Benchmark 节点 (m8i.4xlarge × 9, ASG: eks-test-s4-m8i-benchmark)

| 节点 | Private IP | Taint |
|------|-----------|-------|
| ip-172-31-18-241 | 172.31.18.241 | kata-benchmark=true:NoSchedule |
| ip-172-31-19-254 | 172.31.19.254 | kata-benchmark=true:NoSchedule |
| ip-172-31-19-97 | 172.31.19.97 | kata-benchmark=true:NoSchedule |
| ip-172-31-21-152 | 172.31.21.152 | kata-benchmark=true:NoSchedule |
| ip-172-31-22-253 | 172.31.22.253 | kata-benchmark=true:NoSchedule |
| ip-172-31-24-12 | 172.31.24.12 | kata-benchmark=true:NoSchedule |
| ip-172-31-25-251 | 172.31.25.251 | kata-benchmark=true:NoSchedule |
| ip-172-31-27-93 | 172.31.27.93 | kata-benchmark=true:NoSchedule |
| ip-172-31-29-155 | 172.31.29.155 | (无 taint，untainted) |

### Oversell 节点 (r8i.2xlarge × 1, ASG: eks-test-s4-r8i-oversell)

| 节点 | Private IP | Taint |
|------|-----------|-------|
| ip-172-31-18-5 | 172.31.18.5 | kata-oversell=true:NoSchedule |

### 节点公共配置

- **OS**: Amazon Linux 2023.10.20260216
- **Host Kernel**: 6.12.68-92.122.amzn2023.x86_64
- **containerd**: 2.1.5
- **AMI**: ami-070ee402905300035
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
