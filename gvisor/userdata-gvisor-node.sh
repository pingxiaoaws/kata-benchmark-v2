#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/gvisor-setup.log) 2>&1

echo "=== gVisor Setup Started at $(date) ==="

# 1. Install gVisor binary
ARCH=$(uname -m)
GVISOR_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"
cd /tmp
curl -fsSL "${GVISOR_URL}/runsc" -o runsc
curl -fsSL "${GVISOR_URL}/containerd-shim-runsc-v1" -o containerd-shim-runsc-v1
chmod +x runsc containerd-shim-runsc-v1
mv runsc /usr/local/bin/
mv containerd-shim-runsc-v1 /usr/local/bin/
echo "✓ gVisor installed: $(/usr/local/bin/runsc --version)"

# 2. Write nodeadm config
mkdir -p /etc/nodeadm
cat > /etc/nodeadm/nodeadm-config.yaml << 'EOFNODEADM'
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: test-s4
    region: us-west-2
    apiServerEndpoint: https://5DC16C0D96DE13049FC77E0220AD3B99.gr7.us-west-2.eks.amazonaws.com
    certificateAuthority: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJWjlIWjhWYmxydGN3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TlRFeU1ESXdNRFV4TXpaYUZ3MHpOVEV4TXpBd01EVTJNelphTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUURILzB5Y2lmTEJ6eTBFck9VMHdlUmtqWGhVbk9JMmlwYkZ1NGJHSXN4YlhsMWtIaUhLZXJKTllMM1kKMU9Hb3hDYWgzMk1QTnFERmpNVjJJRk1aODgyM2dQemJFalM4aUowKzlrMmtONUZsSCtmeHJBeWdRTXFzV3AvcQpiRFc2ZWxBbXVBcDVWaUhQQzVZK0djQitMV0thd0ExVGpOME9kL01nRDdmdHBDTXVtY1BPT2ZkTk4yNWI1WE5oCmNhVTQ2VWVEcjl1d09zWlFSbUpKbFlwdVRRSGw1SFJHT1NHVWRIUTEwaEw2Rld6VmZoWDBJTGZScDZVZ3FUb0UKWmo3WGo4UlNoak9FV3VwQjJ1T0hsQ1MvSWljUlpxSlBzUCs5ait4R014bWNsd2RWaUR4UlJGYWJSamdPWTVQOAppQzhZMW82NHFxMVNPZ3h4TGg0a1ZCWnBGTGl4QWdNQkFBR2pXVEJYTUE0R0ExVWREd0VCL3dRRUF3SUNwREFQCkJnTlZIUk1CQWY4RUJUQURBUUgvTUIwR0ExVWREZ1FXQkJRc3B3TWpmUi9FN0cxeUtSdTFaNGVlaFA3ZXhEQVYKQmdOVkhSRUVEakFNZ2dwcmRXSmxjbTVsZEdWek1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQkFRQWxjWXVzMEZOVAo4V0RobzczeHpPU2lEa05QS2w1RGliZUZCVmNOSEQwMFd3WnNLVFFwWURXV0ZSeXVwQmlVYjFGa2ljTkxLamt4Ck8rZHhTZlEvYTh1d3BBSWRTLzBCZ2JYa0w4SWhSamRNNFFVcThZMjNkbU1rdXo1bFY0ZTI0dDlXMXdNS3pEdTIKSzh5d0o4aC9JMmpwUHlJWHhtU2VBTndJQmxsMGo1K3NJUW8vQWlzNWY2ODZyL240T2NoNHphS0VnTjEvYStQVworSHdVZElHSFN1UHlua3ZCNmxISmpBa0R1ODZVYjVPT283R1hrbmR0WFZFNVZjRWFxeXl1VTg5dDEzNFc2NDZSCi9BMVAwY2tKTXkraUNYRFBLbUhvTWxZcVAwVDZUaUhXM1dSNFM4bXQxWmxhQ281YjhIUVlEWlhiYWxvZXNKOS8KUTM1aktlbFR0V2c1Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K
    cidr: 10.100.0.0/16
  kubelet:
    config:
      maxPods: 110
    flags:
      - --node-labels=workload-type=gvisor,runtime=gvisor
      - --register-with-taints=gvisor=true:NoSchedule
EOFNODEADM

# 3. Run nodeadm init
nodeadm init -c file:///etc/nodeadm/nodeadm-config.yaml
echo "✓ nodeadm init completed"

# 4. Add runsc to containerd (use containerd 2.x namespace!)
sleep 10
printf "\n[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]\nruntime_type = \"io.containerd.runsc.v1\"\n" >> /etc/containerd/config.toml

systemctl restart containerd
sleep 5
echo "✓ containerd restarted with runsc handler"
echo "=== gVisor Setup Completed at $(date) ==="
