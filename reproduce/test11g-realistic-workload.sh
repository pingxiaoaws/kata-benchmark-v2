#!/usr/bin/env bash
set -euo pipefail
#
# Test 11g: Realistic Customer Workload Reproduction
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
  # Gateway: nginx + self-traffic loop
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
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 10
      periodSeconds: 10
    lifecycle:
      postStart:
        exec:
          command: ["/bin/sh", "-c", "nohup sh -c 'sleep 5; while true; do for j in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do wget -q -O /dev/null http://localhost/ 2>/dev/null & done; wait; sleep 0.1; done' >/dev/null 2>&1 &"]
  # Config-watcher: sha256 file scanning
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      while true; do
        find /etc -type f -exec sha256sum {} \; > /dev/null 2>&1
        i=0; while [ \$i -lt 10000 ]; do i=\$((i+1)); done
        sleep 1
      done
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
  # Envoy: openssl TLS simulation
  - name: envoy
    image: alpine:3.19
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache openssl >/dev/null 2>&1
      while true; do
        openssl speed -seconds 2 rsa2048 >/dev/null 2>&1
        dd if=/dev/urandom bs=1M count=10 2>/dev/null | openssl enc -aes-256-cbc -pass pass:benchmark -out /dev/null 2>/dev/null
        sleep 0.5
      done
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
  # Wazuh: file integrity monitoring simulation
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      while true; do
        find / -maxdepth 4 -type f 2>/dev/null | while read f; do
          sha256sum "\$f" 2>/dev/null || true
        done
        i=0; while [ \$i -lt 50000 ]; do i=\$((i+1)); done
        sleep 2
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
echo "  Test 11g: Realistic Customer Workload"
echo "============================================================="
echo "Node: $NODE (m8i.2xlarge, 8 vCPU, 32 GiB)"
echo "Pods: $MAX_PODS × 4 containers"
echo "============================================================="
echo ""

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
    kubectl get pod "sandbox-$i" -n "t11g-$i" 2>/dev/null
  fi
done

echo ""
echo "Waiting 60s for workloads to warm up..."
sleep 60

echo ""
echo "=== Pod Status ==="
kubectl get pods -A -l app=customer-repro-v2 -o wide

echo ""
echo "=== Host CPU ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'top -bn1 | head -5'

echo ""
echo "=== QEMU processes ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  ps -eo pid,%cpu,%mem,rss,vsz,comm --sort=-%cpu --no-headers 2>/dev/null | \
  grep -E "qemu-system|virtiofsd" | head -20

echo ""
echo "=== Memory ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h

echo ""
echo "Done. Pods running with realistic workload. No auto-cleanup."
