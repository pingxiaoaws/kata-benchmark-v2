#!/usr/bin/env bash
set -euo pipefail
#
# Test 11g v2: Match Customer Steady-State Profile
#   - Low CPU (~8-15%)
#   - High memory (~2.5 GiB RSS per QEMU)
#   - 7 pods × 4 containers on m8i.2xlarge (8 vCPU, 32 GiB)
#
NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"
MAX_PODS=${1:-7}

gen_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: customer-repro-v2
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
  # Gateway: nginx serving, light periodic self-check
  - name: gateway
    image: nginx:1.27
    resources:
      requests:
        cpu: "150m"
        memory: "1Gi"
      limits:
        cpu: "1500m"
        memory: "2Gi"
    readinessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 5
      periodSeconds: 10
    livenessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 10
      periodSeconds: 10
  # Config-watcher: hold ~600MiB memory, light CPU
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      # Allocate 600MiB resident memory
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=600 2>/dev/null
      # Light config watching loop
      while true; do
        cat /proc/loadavg >/dev/null
        sleep 5
      done
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
  # Envoy: hold ~600MiB memory, light CPU
  - name: envoy
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      # Allocate 600MiB resident memory
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=600 2>/dev/null
      # Light proxy simulation
      while true; do
        dd if=/dev/zero of=/dev/null bs=1k count=10 2>/dev/null
        sleep 3
      done
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
  # Wazuh: hold ~600MiB memory, light FIM
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      # Allocate 600MiB resident memory
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=600 2>/dev/null
      # Light file integrity check
      while true; do
        find /etc -type f -maxdepth 2 2>/dev/null | wc -l >/dev/null
        sleep 10
      done
    resources:
      requests:
        cpu: "100m"
        memory: "512Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
EOF
}

echo "============================================================="
echo "  Test 11g v2: Customer Steady-State Profile"
echo "  Target: ~8% CPU, ~2.5 GiB RSS per QEMU, 7 pods"
echo "============================================================="

sleep 5  # wait for ns cleanup

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
    echo "  ✅ sandbox-$i Ready"
  else
    echo "  ❌ sandbox-$i not ready"
  fi
done

echo ""
echo "Waiting 90s for memory allocation to complete..."
sleep 90

echo ""
echo "=== Pod Status ==="
kubectl get pods -A -l app=customer-repro-v2

echo ""
echo "=== QEMU RSS ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  ps -eo pid,%cpu,%mem,rss,comm --sort=-rss --no-headers 2>/dev/null | grep qemu-system

echo ""
echo "=== Host CPU ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'top -bn1 | head -5' 2>/dev/null

echo ""
echo "=== Host Memory ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -m 2>/dev/null

echo ""
echo "Done. No auto-cleanup."
