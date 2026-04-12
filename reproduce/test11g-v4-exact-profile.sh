#!/usr/bin/env bash
set -euo pipefail
#
# Test 11g v4: Exact Customer Resource Profile
#
# Target: 7 VMs, total ~4.2 cores CPU + ~17 GiB memory (QEMU RSS)
# Per VM: ~0.6 core CPU, ~2.4 GiB RSS
#
# Key: to push QEMU RSS, guest must *touch real memory pages*, 
# not just write to virtiofs (/tmp). We use anonymous mmap via 
# a simple busybox memory hog that malloc+memsets.
#
NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"
MAX_PODS=${1:-7}

# Each container allocates GUEST_MEM_MB via malloc+touch (pushes QEMU RSS)
# ~2.0 GiB guest usage + ~400 MiB QEMU overhead ≈ 2.4 GiB RSS
GUEST_MEM_MB=2000

gen_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: customer-repro-v4
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    workload-type: kata
    kubernetes.io/hostname: ${NODE}
  tolerations:
  - key: ${TAINT_KEY}
    operator: Equal
    value: "true"
    effect: NoSchedule
  overhead:
    memory: "640Mi"
    cpu: "500m"
  containers:
  # Gateway: nginx (low CPU, minimal memory)
  - name: gateway
    image: nginx:1.27
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "1500m", memory: "2Gi" }
    readinessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 5
      periodSeconds: 10
    livenessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 10
      periodSeconds: 10
  # Config-watcher: allocate+touch 700MiB anonymous memory, light CPU
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      # Allocate anonymous memory via /dev/shm (tmpfs in guest, backed by guest RAM)
      dd if=/dev/urandom of=/dev/shm/memblock bs=1M count=700 2>/dev/null
      # Light periodic work
      while true; do
        cat /proc/loadavg >/dev/null
        sleep 5
      done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  # Envoy: allocate+touch 700MiB, light CPU work
  - name: envoy
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock2 bs=1M count=700 2>/dev/null
      # Light CPU: periodic work simulating proxy
      while true; do
        i=0; while [ \$i -lt 5000 ]; do i=\$((i+1)); done
        sleep 2
      done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  # Wazuh: allocate+touch 600MiB, light FIM
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock3 bs=1M count=600 2>/dev/null
      # Light FIM
      while true; do
        find /etc -type f -maxdepth 2 2>/dev/null | wc -l >/dev/null
        sleep 10
      done
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
EOF
}

echo "============================================================="
echo "  Test 11g v4: Exact Customer Profile"
echo "  7 VMs × ~2.4 GiB RSS + ~0.6 core = 4.2 cores + 17 GiB"
echo "  Memory via guest /dev/shm (anonymous, pushes QEMU RSS)"
echo "============================================================="

for i in $(seq 1 $MAX_PODS); do
  ns="t11g-$i"
  kubectl create ns "$ns" 2>/dev/null || true
  gen_pod "sandbox-$i" "$ns" | kubectl apply -f -
  echo "  sandbox-$i created"
done

echo ""
echo "Waiting for pods to be Ready..."
for i in $(seq 1 $MAX_PODS); do
  if kubectl wait --for=condition=Ready "pod/sandbox-$i" -n "t11g-$i" --timeout=180s 2>/dev/null; then
    echo "  ✅ sandbox-$i"
  else
    echo "  ❌ sandbox-$i"
  fi
done

echo ""
echo "Waiting 60s for memory allocation to settle..."
sleep 60

echo ""
echo "=== Pod Status ==="
kubectl get pods -A -l app=customer-repro-v4

echo ""
echo "=== QEMU top (RES/SHR) ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  sh -c 'top -bn1 -w 200 | grep qemu-system | head -10' 2>/dev/null

echo ""
echo "=== virtiofsd ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  sh -c 'top -bn1 -w 200 | grep virtiofsd | head -14' 2>/dev/null

echo ""
echo "=== Totals (QEMU only) ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
  total_rss=0; count=0
  for pid in \$(pgrep qemu-system); do
    rss=\$(cat /proc/\$pid/status | grep VmRSS | awk "{print \\\$2}")
    total_rss=\$((total_rss + rss))
    count=\$((count + 1))
  done
  echo "QEMU count: \$count"
  echo "Total QEMU RSS: \$((total_rss / 1024)) MiB (\$(echo "scale=1; \$total_rss / 1024 / 1024" | bc) GiB)"
  echo "Average per VM: \$((total_rss / count / 1024)) MiB"
' 2>/dev/null

echo ""
echo "=== Host CPU ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'top -bn1 | head -5' 2>/dev/null

echo ""
echo "=== Host Memory ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h 2>/dev/null

echo ""
echo "Done. No auto-cleanup."
