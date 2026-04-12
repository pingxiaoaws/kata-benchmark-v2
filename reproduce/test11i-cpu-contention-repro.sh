#!/usr/bin/env bash
set -euo pipefail
#
# Test 11i: Reproduce CPU Contention → Dead Agent Cascade
#
# Demonstrates how vCPU overcommit + CPU load → kata-agent heartbeat timeout
# → "Dead agent" → all containers exit 255 → cascade across all VMs
#
# Usage: bash test11i-cpu-contention-repro.sh [deploy|stress|observe|cleanup]
#

NODE="ip-172-31-17-237.us-west-2.compute.internal"
NS_PREFIX="t11i"
MAX_PODS=${MAX_PODS:-4}       # 4 pods on 8 vCPU host, enough to demonstrate
STRESS_WORKERS=${STRESS_WORKERS:-4}  # CPU workers per VM

gen_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: cpu-contention-repro
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
    workload-type: kata
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
  - key: kata-oversell
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  - name: app
    image: nginx:1.27
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "1000m", memory: "512Mi" }
    livenessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 1
    readinessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 5
      periodSeconds: 5
  - name: worker
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo "Worker ready. Waiting for stress signal..."
      # Wait for /tmp/start-stress marker file
      while [ ! -f /tmp/start-stress ]; do sleep 1; done
      echo "Starting CPU stress: ${STRESS_WORKERS} workers"
      # Pure shell CPU burn (no stress-ng needed)
      for i in \$(seq 1 ${STRESS_WORKERS}); do
        while true; do :; done &
      done
      echo "Stress started. PIDs: \$(jobs -p)"
      wait
    resources:
      requests: { cpu: "100m", memory: "64Mi" }
      limits:   { cpu: "2000m", memory: "128Mi" }
EOF
}

deploy() {
  echo "============================================================="
  echo "  Deploying ${MAX_PODS} Kata pods (default_vcpus=5)"
  echo "  vCPU threads: ${MAX_PODS} × 5 = $((MAX_PODS * 5)) on 8 physical cores"
  echo "============================================================="

  for i in $(seq 1 $MAX_PODS); do
    local ns="${NS_PREFIX}-$i"
    kubectl create ns "$ns" 2>/dev/null || true
    gen_pod "sandbox-$i" "$ns" | kubectl apply -f -
    echo "  Created sandbox-$i"
  done

  echo ""
  echo "Waiting for pods to be Ready..."
  for i in $(seq 1 $MAX_PODS); do
    if kubectl wait --for=condition=Ready "pod/sandbox-$i" -n "${NS_PREFIX}-$i" --timeout=180s 2>/dev/null; then
      echo "  ✅ sandbox-$i"
    else
      echo "  ❌ sandbox-$i"
    fi
  done

  echo ""
  echo "=== Baseline (no CPU stress yet) ==="
  kubectl get pods -A -l app=cpu-contention-repro
  echo ""
  echo "All pods Running with 0 restarts."
  echo "Run: $0 stress    to inject CPU load"
}

stress() {
  echo "============================================================="
  echo "  Injecting CPU stress: ${STRESS_WORKERS} workers per VM"
  echo "  Total CPU threads: ${MAX_PODS} × ${STRESS_WORKERS} = $((MAX_PODS * STRESS_WORKERS)) workers"
  echo "  + QEMU vCPU threads: ${MAX_PODS} × 5 = $((MAX_PODS * 5))"
  echo "  All competing for 8 physical cores"
  echo "============================================================="

  for i in $(seq 1 $MAX_PODS); do
    kubectl exec -n "${NS_PREFIX}-$i" "sandbox-$i" -c worker -- \
      sh -c "touch /tmp/start-stress" 2>/dev/null &
    echo "  Triggered stress in sandbox-$i"
  done
  wait

  echo ""
  echo "CPU stress injected. Monitoring for Dead Agent..."
  echo "Watch: kubectl get pods -A -l app=cpu-contention-repro -w"
  echo ""
  echo "Run: $0 observe   to check results"
}

observe() {
  echo "============================================================="
  echo "  Observing pod status"
  echo "============================================================="

  echo ""
  echo "=== Pod Status ==="
  kubectl get pods -A -l app=cpu-contention-repro -o wide 2>/dev/null

  echo ""
  echo "=== Host CPU ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    sh -c 'top -bn1 | head -5' 2>/dev/null

  echo ""
  echo "=== QEMU processes ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    sh -c 'top -bn1 -w 200 | grep qemu-system' 2>/dev/null

  echo ""
  echo "=== Restart summary ==="
  for i in $(seq 1 $MAX_PODS); do
    local restarts
    restarts=$(kubectl get pod "sandbox-$i" -n "${NS_PREFIX}-$i" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "N/A")
    echo "  sandbox-$i: $restarts restarts"
  done

  echo ""
  echo "=== Recent events ==="
  for i in $(seq 1 $MAX_PODS); do
    echo "--- sandbox-$i ---"
    kubectl get events -n "${NS_PREFIX}-$i" --sort-by='.lastTimestamp' 2>/dev/null | tail -5
  done

  echo ""
  echo "Expected: Multiple restarts, 'Dead agent' in containerd logs"
  echo "Check: journalctl -u containerd --since '5 min ago' | grep -E 'Dead agent|exit_status:255'"
}

cleanup() {
  echo "=== Cleanup ==="
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "${NS_PREFIX}-$i" --force --grace-period=0 2>/dev/null &
  done
  wait
  sleep 10
  echo "All ${NS_PREFIX} namespaces deleted."
}

case "${1:-deploy}" in
  deploy)  deploy ;;
  stress)  stress ;;
  observe) observe ;;
  cleanup) cleanup ;;
  *)
    echo "Usage: $0 [deploy|stress|observe|cleanup]"
    echo ""
    echo "Workflow:"
    echo "  1. $0 deploy    → Create ${MAX_PODS} Kata pods (baseline, no stress)"
    echo "  2. $0 stress    → Inject CPU burn in all pods"
    echo "  3. $0 observe   → Check for Dead Agent / restarts"
    echo "  4. $0 cleanup   → Delete everything"
    echo ""
    echo "Environment variables:"
    echo "  MAX_PODS=4          Number of pods (default: 4)"
    echo "  STRESS_WORKERS=4    CPU workers per pod (default: 4)"
    exit 1
    ;;
esac
