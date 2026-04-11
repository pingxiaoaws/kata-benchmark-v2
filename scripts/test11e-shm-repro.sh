#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/v2-lib.sh"

NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"
RESULTS="/home/ec2-user/kata-benchmark-v2/results"
CSV="$RESULTS/v2-test11e-shm-repro.csv"
LOG="$RESULTS/v2-test11e-shm-stdout.log"
MAX_PODS=10
SHM_LIMIT="14G"  # Simulate customer's constrained /dev/shm

log() { echo "[$(date '+%H:%M:%S')] $*"; }
exec > >(tee -a "$LOG") 2>&1

gen_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
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
  - name: nginx
    image: nginx:1.27
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"
  - name: sleep
    image: busybox:1.36
    command: ["sleep", "infinity"]
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
}

snapshot() {
  local phase="$1" target="$2"
  local running pending failed not_ready restarts
  local node_cpu mem_avail shm_used shm_avail qemu_count qemu_cpu ts

  # Pod counts across all test namespaces
  running=$(kubectl get pods -A -l app=shm-test --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  pending=$(kubectl get pods -A -l app=shm-test --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
  failed=$(kubectl get pods -A -l app=shm-test --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
  not_ready=$(kubectl get pods -A -l app=shm-test --no-headers 2>/dev/null | awk '$3 !~ /Running|Completed|Succeeded/' | wc -l)
  restarts=$(kubectl get pods -A -l app=shm-test --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')

  node_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    read -r _ _ _ _ idle rest < /proc/stat; sleep 1; read -r _ _ _ _ idle2 rest2 < /proc/stat
    total=$((idle + $(echo $rest | tr " " "+")))
    total2=$((idle2 + $(echo $rest2 | tr " " "+")))
    printf "%.1f" $(echo "100 * (1 - ($idle2 - $idle) / ($total2 - $total))" | bc -l)
  ' 2>/dev/null || echo "0")

  mem_avail=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

  shm_used=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df /dev/shm --output=used -B1M 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
  shm_avail=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df /dev/shm --output=avail -B1M 2>/dev/null | tail -1 | tr -d ' ' || echo "0")

  qemu_count=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- pgrep -c qemu-system 2>/dev/null || echo "0")
  qemu_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo %cpu,comm --no-headers | grep qemu-system | awk "{s+=\$1} END {printf \"%.1f\", s+0}"
  ' 2>/dev/null || echo "0")

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "  phase=$phase target=$target running=$running failed=$failed restarts=$restarts"
  log "  node_cpu=${node_cpu}% mem_avail=${mem_avail}MiB shm_used=${shm_used}MiB shm_avail=${shm_avail}MiB qemu=$qemu_count(${qemu_cpu}%)"
  echo "$phase,$target,$running,$pending,$failed,$not_ready,$restarts,$node_cpu,$mem_avail,$shm_used,$shm_avail,$qemu_count,$qemu_cpu,$ts" >> "$CSV"
}

cleanup() {
  log "=== Cleanup (trap) ==="
  log "Cleaning up..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11e-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  # Restore /dev/shm
  log "Restoring /dev/shm to default size..."
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- mount -o remount,size=16G /dev/shm 2>/dev/null || true
  log "Waiting for namespace cleanup..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl wait --for=delete ns/"t11e-$i" --timeout=60s 2>/dev/null || true
  done
  log "Done."
}
trap cleanup EXIT

main() {
  log "=== Test 11e: /dev/shm Exhaustion Reproduction ==="
  log "Node: $NODE (m8i.2xlarge, 8 vCPU, 32 GiB)"
  log "Kata config: default_vcpus=5, default_memory=2048"
  log "Plan: shrink /dev/shm to $SHM_LIMIT, deploy pods until failure"
  log ""

  # Clean any leftovers
  log "Cleaning up any leftover namespaces..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11e-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  sleep 5

  # Shrink /dev/shm
  log "Shrinking /dev/shm to $SHM_LIMIT..."
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- mount -o remount,size=$SHM_LIMIT /dev/shm 2>/dev/null
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df -h /dev/shm 2>/dev/null
  log ""

  echo "phase,target_pods,running,pending,failed,not_ready,total_restarts,node_cpu_pct,mem_available_MiB,shm_used_MiB,shm_avail_MiB,qemu_count,qemu_total_cpu_pct,timestamp" > "$CSV"

  # Baseline
  log "=== Phase 0: Baseline ==="
  sleep 3
  snapshot "baseline" 0
  log ""

  # Deploy pods one by one
  for i in $(seq 1 $MAX_PODS); do
    log "=== Phase $i: Deploying pod shm-$i ($i / $MAX_PODS) ==="
    local ns="t11e-$i"
    kubectl create ns "$ns" 2>/dev/null || true
    kubectl label ns "$ns" app=shm-test --overwrite 2>/dev/null || true

    # Add app label to pod
    gen_pod "shm-$i" "$ns" | sed 's/metadata:/metadata:\n  labels:\n    app: shm-test/' | kubectl apply -f - 2>/dev/null

    log "  Waiting up to 120s for pod Ready..."
    if kubectl wait --for=condition=Ready "pod/shm-$i" -n "$ns" --timeout=120s 2>/dev/null; then
      log "  ✅ Pod shm-$i is Ready"
    else
      log "  ❌ Pod shm-$i FAILED to become Ready"
      # Capture diagnostics
      log "  Pod status:"
      kubectl get pod "shm-$i" -n "$ns" -o wide 2>/dev/null || true
      kubectl describe pod "shm-$i" -n "$ns" 2>/dev/null | tail -20
      log "  /dev/shm status:"
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df -h /dev/shm 2>/dev/null || true
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- ls -lh /dev/shm/ 2>/dev/null || true
      # Capture QEMU processes
      log "  QEMU processes:"
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'ps -eo pid,%cpu,%mem,rss,comm --sort=-%mem | grep qemu-system | grep -v grep' 2>/dev/null || true
      # Check dmesg for OOM
      log "  Recent dmesg (OOM/memory):"
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- dmesg --time-format iso | tail -30 2>/dev/null | grep -i "oom\|kill\|memory\|shm\|out of" || echo "  (none)"
    fi

    sleep 10
    snapshot "deployed-$i" "$i"

    # Check /dev/shm after each deployment
    log "  /dev/shm:"
    kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df -h /dev/shm 2>/dev/null
    log "  QEMU RSS:"
    kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'ps -eo pid,%cpu,%mem,rss,comm --sort=-%mem | grep qemu-system | grep -v grep' 2>/dev/null || true
    log ""

    # If we've hit failure, collect a couple more samples and stop
    local fail_count
    fail_count=$(kubectl get pods -A -l app=shm-test --no-headers 2>/dev/null | awk '$3 ~ /Error|CrashLoop|OOM/' | wc -l)
    if [[ "$fail_count" -gt 0 ]]; then
      log "=== Failure detected! Collecting steady-state samples ==="
      for s in 1 2 3; do
        sleep 15
        snapshot "post-fail-$s" "$i"
      done
      break
    fi
  done

  log ""
  log "=== Final Status ==="
  kubectl get pods -A -l app=shm-test -o wide 2>/dev/null || true
  log ""
  log "=== /dev/shm Final ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df -h /dev/shm 2>/dev/null
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- ls -lh /dev/shm/ 2>/dev/null
  log ""
  log "=== CSV ==="
  cat "$CSV"
  log ""
  log "Test 11e complete."
}

main "$@"
