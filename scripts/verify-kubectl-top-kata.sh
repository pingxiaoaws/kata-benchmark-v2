#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Verify: What does kubectl top actually show for kata pods?
# Deploy runc + kata-qemu pause pods, compare:
#   1. kubectl top pod (metrics-server)
#   2. Host cgroup cpu.stat / memory.current
#   3. Host QEMU process RSS
# ============================================================

NODE="ip-172-31-18-241.us-west-2.compute.internal"
NS="verify-top"
PAUSE_IMAGE="registry.k8s.io/pause:3.10"
TAINT_KEY="kata-benchmark"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
  log "Cleaning up..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# Setup
cleanup
sleep 3
kubectl create namespace "$NS" 2>/dev/null

# Deploy hostpod for host-level inspection
log "Deploying hostpod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hostpod
  namespace: $NS
spec:
  nodeName: $NODE
  hostPID: true
  hostNetwork: true
  tolerations:
  - key: "$TAINT_KEY"
    value: "true"
    effect: NoSchedule
  containers:
  - name: nsenter
    image: alpine:3.20
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: hostroot
      mountPath: /host
  volumes:
  - name: hostroot
    hostPath:
      path: /
EOF
kubectl wait -n "$NS" pod/hostpod --for=condition=Ready --timeout=120s

hostexec() {
  kubectl exec -n "$NS" hostpod -- nsenter -t 1 -m -u -i -n -p -- "$@"
}

# Deploy runc pause pod
log "Deploying runc pause pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pause-runc
  namespace: $NS
spec:
  nodeName: $NODE
  tolerations:
  - key: "$TAINT_KEY"
    value: "true"
    effect: NoSchedule
  containers:
  - name: pause
    image: $PAUSE_IMAGE
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
  terminationGracePeriodSeconds: 0
EOF

# Deploy kata-qemu pause pod
log "Deploying kata-qemu pause pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pause-kata
  namespace: $NS
spec:
  runtimeClassName: kata-qemu
  nodeName: $NODE
  tolerations:
  - key: "$TAINT_KEY"
    value: "true"
    effect: NoSchedule
  containers:
  - name: pause
    image: $PAUSE_IMAGE
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
  terminationGracePeriodSeconds: 0
EOF

log "Waiting for pods..."
kubectl wait -n "$NS" pod/pause-runc --for=condition=Ready --timeout=120s
kubectl wait -n "$NS" pod/pause-kata --for=condition=Ready --timeout=180s

# Wait for metrics to populate (metrics-server needs ~60s)
log "Waiting 90s for metrics-server to populate..."
sleep 90

echo ""
echo "============================================"
echo "=== 1. kubectl top pod ==="
echo "============================================"
kubectl top pod -n "$NS" --no-headers 2>&1 || echo "kubectl top FAILED"

echo ""
echo "============================================"
echo "=== 2. kubectl top pod --containers ==="
echo "============================================"
kubectl top pod -n "$NS" --containers --no-headers 2>&1 || echo "kubectl top --containers FAILED"

echo ""
echo "============================================"
echo "=== 3. Host cgroup inspection ==="
echo "============================================"

for podname in pause-runc pause-kata; do
  echo ""
  echo "--- Pod: $podname ---"
  pod_uid=$(kubectl get pod -n "$NS" "$podname" -o jsonpath='{.metadata.uid}')
  echo "  Pod UID: $pod_uid"
  
  # Find cgroup path
  echo "  Searching cgroup paths..."
  hostexec sh -c "find /sys/fs/cgroup -path '*${pod_uid}*' -name 'memory.current' 2>/dev/null" || echo "  (no memory.current found)"
  hostexec sh -c "find /sys/fs/cgroup -path '*${pod_uid}*' -name 'cpu.stat' 2>/dev/null" || echo "  (no cpu.stat found)"
  
  # Read memory.current
  echo "  memory.current:"
  hostexec sh -c "find /sys/fs/cgroup -path '*${pod_uid}*' -name 'memory.current' 2>/dev/null | while read f; do echo \"    \$f = \$(cat \$f)\"; done" || echo "  N/A"
  
  # Read cpu.stat
  echo "  cpu.stat:"
  hostexec sh -c "find /sys/fs/cgroup -path '*${pod_uid}*' -name 'cpu.stat' 2>/dev/null | head -1 | while read f; do echo \"    \$f:\"; cat \$f | sed 's/^/      /'; done" || echo "  N/A"
  
  # Read cpu.stat usage_usec specifically
  echo "  cpu usage_usec from all cgroup levels:"
  hostexec sh -c "find /sys/fs/cgroup -path '*${pod_uid}*' -name 'cpu.stat' 2>/dev/null | while read f; do usage=\$(grep usage_usec \$f | awk '{print \$2}'); echo \"    \$f → usage_usec=\$usage\"; done" || echo "  N/A"
done

echo ""
echo "============================================"
echo "=== 4. QEMU processes on host ==="
echo "============================================"
hostexec sh -c "ps aux | grep qemu-system | grep -v grep" || echo "  No qemu-system process found"

echo ""
echo "============================================"
echo "=== 5. cloud-hypervisor processes on host ==="  
echo "============================================"
hostexec sh -c "ps aux | grep cloud-hypervisor | grep -v grep" || echo "  No cloud-hypervisor process found"

echo ""
echo "============================================"
echo "=== 6. QEMU process cgroup membership ==="
echo "============================================"
QEMU_PID=$(hostexec sh -c "pgrep -f qemu-system | head -1" 2>/dev/null || echo "")
if [[ -n "$QEMU_PID" ]]; then
  echo "QEMU PID: $QEMU_PID"
  echo "cgroup:"
  hostexec cat "/proc/${QEMU_PID}/cgroup"
  echo ""
  echo "VmRSS:"
  hostexec grep -E "^(VmRSS|RssAnon|RssFile|RssShmem)" "/proc/${QEMU_PID}/status"
else
  echo "No QEMU process found"
fi

echo ""
echo "============================================"
echo "=== 7. metrics-server raw API ==="
echo "============================================"
echo "--- Pod metrics from metrics.k8s.io ---"
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/$NS/pods" 2>&1 | python3 -m json.tool 2>/dev/null || echo "metrics API failed"

log "=== Verification complete ==="
