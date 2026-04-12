#!/usr/bin/env bash
set -euo pipefail
#
# Test 11g v3: Match Customer Exact Resource Profile
#
# Target: 7 VMs total ~4.2 cores CPU + ~17 GiB memory
#   Per VM: ~0.6 cores (~60% of 1 core) + ~2.43 GiB RSS
#
# Distribution (slight variation for realism):
#   VM 1: 0.65 core, 2.6 GiB  (slightly hot)
#   VM 2: 0.55 core, 2.3 GiB
#   VM 3: 0.60 core, 2.5 GiB
#   VM 4: 0.70 core, 2.6 GiB  (hottest)
#   VM 5: 0.55 core, 2.3 GiB
#   VM 6: 0.60 core, 2.4 GiB
#   VM 7: 0.55 core, 2.2 GiB  (lightest)
#   Total: 4.20 cores, 16.9 GiB
#
# Memory strategy:
#   QEMU base RSS ≈ 400 MiB (VM overhead)
#   /dev/shm (memory-backend-file) ≈ stays in SHR
#   Guest allocation needed: ~2.0-2.2 GiB per VM → 3 containers × ~700 MiB each
#
# CPU strategy:
#   Each VM gets a busybox CPU burner calibrated to target CPU%
#   60% of 1 core on 5-vCPU VM = light but sustained load
#
NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"

# Per-VM config: MEM_MB is total guest allocation, CPU_LOAD is stress-ng cpu-load%
declare -a VM_MEM=(2200 1900 2100 2200 1900 2000 1800)
declare -a VM_CPU=(65 55 60 70 55 60 55)

gen_pod() {
  local name="$1" ns="$2" mem_mb="$3" cpu_pct="$4"
  local mem_per_container=$((mem_mb / 3))
  local mem_remainder=$((mem_mb - mem_per_container * 2))  # last container gets remainder
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: customer-repro-v3
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
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=${mem_per_container} 2>/dev/null
      while true; do cat /proc/loadavg >/dev/null; sleep 5; done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  - name: envoy
    image: alpine:3.19
    command: ["/bin/sh", "-c"]
    args:
    - |
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=${mem_per_container} 2>/dev/null
      # CPU load: sustained ${cpu_pct}% of 1 core via openssl
      apk add --no-cache openssl >/dev/null 2>&1
      while true; do
        openssl speed -seconds 1 rsa2048 >/dev/null 2>&1
        # Sleep to calibrate CPU to ~${cpu_pct}%
        usleep_ms=\$((100 - ${cpu_pct}))
        sleep 0.\${usleep_ms}
      done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      mkdir -p /tmp/mem
      dd if=/dev/urandom of=/tmp/mem/data bs=1M count=${mem_remainder} 2>/dev/null
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
echo "  Test 11g v3: Customer Exact Resource Profile"
echo "  Target: 7 VMs, total ~4.2 cores CPU + ~17 GiB memory"
echo "============================================================="

for i in $(seq 1 7); do
  idx=$((i - 1))
  ns="t11g-$i"
  kubectl create ns "$ns" 2>/dev/null || true
  gen_pod "sandbox-$i" "$ns" "${VM_MEM[$idx]}" "${VM_CPU[$idx]}" | kubectl apply -f -
  echo "  sandbox-$i: mem=${VM_MEM[$idx]}MiB cpu_target=${VM_CPU[$idx]}%"
done

echo ""
echo "Waiting for pods to be Ready..."
for i in $(seq 1 7); do
  if kubectl wait --for=condition=Ready "pod/sandbox-$i" -n "t11g-$i" --timeout=180s 2>/dev/null; then
    echo "  ✅ sandbox-$i"
  else
    echo "  ❌ sandbox-$i"
  fi
done

echo ""
echo "Waiting 90s for memory allocation + CPU calibration..."
sleep 90

echo ""
echo "=== Pod Status ==="
kubectl get pods -A -l app=customer-repro-v3

echo ""
echo "=== QEMU + virtiofsd (top) ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
  sh -c 'top -bn1 -w 200 | grep -E "qemu-system|virtiofsd" | head -20' 2>/dev/null

echo ""
echo "=== Totals ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
  total_cpu=0; total_mem=0
  while read pid cpu mem rss comm; do
    total_cpu=$(echo "$total_cpu + $cpu" | bc)
    total_mem=$((total_mem + rss))
  done < <(ps -eo pid,%cpu,%mem,rss,comm --sort=-rss --no-headers | grep -E "qemu-system|virtiofsd")
  echo "Total CPU: ${total_cpu}%  (= $(echo "$total_cpu / 100" | bc -l | head -c5) cores)"
  echo "Total RSS: $((total_mem / 1024)) MiB  (= $(echo "scale=1; $total_mem / 1024 / 1024" | bc) GiB)"
' 2>/dev/null

echo ""
echo "=== Host CPU ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'top -bn1 | head -5' 2>/dev/null

echo ""
echo "=== Host Memory ==="
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h 2>/dev/null

echo ""
echo "Done. No auto-cleanup."
