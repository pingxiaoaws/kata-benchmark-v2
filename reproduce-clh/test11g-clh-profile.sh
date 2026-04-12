#!/usr/bin/env bash
set -euo pipefail
#
# Test 11g-clh: Same as Test 11g v4 but using kata-clh runtime
#
# Compare kata-clh vs kata-qemu memory profile with identical workloads
# 7 VMs, same container config, same /dev/shm memory allocation
#

NODE="ip-172-31-19-254.us-west-2.compute.internal"
NS_PREFIX="t11g-clh"
MAX_PODS=${1:-7}
RUNTIME_CLASS="kata-clh"

gen_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: clh-repro-v4
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  nodeSelector:
    workload-type: kata
    kubernetes.io/hostname: ${NODE}
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
  - key: kata-oversell
    operator: Equal
    value: "true"
    effect: NoSchedule
  - key: kata-benchmark
    operator: Equal
    value: "true"
    effect: NoSchedule
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
  # Config-watcher: allocate+touch 700MiB via /dev/shm
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock bs=1M count=700 2>/dev/null
      while true; do
        cat /proc/loadavg >/dev/null
        sleep 5
      done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  # Envoy: allocate+touch 700MiB
  - name: envoy
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock2 bs=1M count=700 2>/dev/null
      while true; do
        i=0; while [ \$i -lt 5000 ]; do i=\$((i+1)); done
        sleep 2
      done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  # Wazuh: allocate+touch 600MiB
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock3 bs=1M count=600 2>/dev/null
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
echo "  Test 11g-clh: Cloud Hypervisor Memory Profile"
echo "  Runtime: ${RUNTIME_CLASS}"
echo "  Node: ${NODE}"
echo "  ${MAX_PODS} VMs × same workload as QEMU test"
echo "============================================================="

for i in $(seq 1 $MAX_PODS); do
  ns="${NS_PREFIX}-$i"
  kubectl create ns "$ns" 2>/dev/null || true
  gen_pod "sandbox-$i" "$ns" | kubectl apply -f -
  echo "  sandbox-$i created"
done

echo ""
echo "Waiting for pods to be Ready..."
FAILED=0
for i in $(seq 1 $MAX_PODS); do
  if kubectl wait --for=condition=Ready "pod/sandbox-$i" -n "${NS_PREFIX}-$i" --timeout=180s 2>/dev/null; then
    echo "  ✅ sandbox-$i"
  else
    echo "  ❌ sandbox-$i"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Waiting 90s for memory allocation to settle..."
sleep 90

echo ""
echo "=== Pod Status ==="
kubectl get pods -A -l app=clh-repro-v4 -o wide

echo ""
echo "=== kubectl top pod ==="
kubectl top pod -A -l app=clh-repro-v4 2>/dev/null

echo ""
echo "=== kubectl top pod --containers ==="
kubectl top pod -A -l app=clh-repro-v4 --containers 2>/dev/null

echo ""
echo "=== kubectl top node ==="
kubectl top node ${NODE} 2>/dev/null

echo ""
echo "=== CLH processes (top) ==="
# Need a hostmon on this node or use SSH
ssh ${NODE} 'top -bn1 -w 200 | grep -E "cloud-hypervisor|clh" | head -14' 2>/dev/null || \
  echo "(SSH not available; check host manually with: top | grep cloud-hypervisor)"

echo ""
echo "=== Host free ==="
ssh ${NODE} 'free -m' 2>/dev/null || echo "(SSH not available)"

echo ""
echo "=== CLH RSS totals ==="
ssh ${NODE} '
total_rss=0; count=0
for pid in $(pgrep -f cloud-hypervisor); do
  rss=$(grep VmRSS /proc/$pid/status 2>/dev/null | awk "{print \$2}")
  if [ -n "$rss" ]; then
    total_rss=$((total_rss + rss))
    count=$((count + 1))
  fi
done
echo "CLH count: $count"
if [ $count -gt 0 ]; then
  echo "Total CLH RSS: $((total_rss / 1024)) MiB"
  echo "Average per VM: $((total_rss / count / 1024)) MiB"
fi
' 2>/dev/null || echo "(SSH not available)"

echo ""
echo "============================================================="
echo "  Failed: ${FAILED}/${MAX_PODS}"
echo "  Done. No auto-cleanup."
echo "  Cleanup: for i in \$(seq 1 ${MAX_PODS}); do kubectl delete ns ${NS_PREFIX}-\$i --force --grace-period=0; done"
echo "============================================================="
