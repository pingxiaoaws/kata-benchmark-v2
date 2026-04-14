#!/usr/bin/env bash
# max-pod-test-fullload-gvisor.sh — Max pod density test with FULL CPU + memory pressure
# gVisor (runsc) on m8i.2xlarge (8 vCPU, 32 GiB)
#
# Same workload as kata stress tests for fair comparison.
# gVisor has NO VM overhead — pure userspace kernel isolation.
#
# Usage: ./max-pod-test-fullload-gvisor.sh [target_node]
set -euo pipefail

NODE="${1:?Usage: $0 <node>}"
RUNTIME="gvisor"
MAX_PODS=30           # gVisor should support more pods (no VM overhead)
SETTLE_SECS=90        # same settle time as kata tests
RESULTS_CSV="results-fullload-gvisor.csv"
LOG_FILE="test-fullload-gvisor.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

# ---------- Pre-flight ----------
log "=== Max Pod Full-Load Test: gVisor (runsc) on $NODE ==="
log "Checking node..."
kubectl get node "$NODE" -o jsonpath='{.metadata.name} {.status.allocatable.cpu} cpu, {.status.allocatable.memory} mem' | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

ALLOC_CPU=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}' | sed 's/m//')
ALLOC_MEM_KI=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//')
ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
log "Node allocatable: ${ALLOC_CPU}m CPU, ${ALLOC_MEM_MI} MiB memory"

# Baseline
log "Collecting baseline..."
BASELINE_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A")
log "Baseline kubectl top node: $BASELINE_NODE"

NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
ssh_node() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$NODE_IP" "$@" 2>/dev/null; }
BASELINE_FREE=$(ssh_node "free -m | grep Mem" || echo "N/A")
log "Baseline free -m: $BASELINE_FREE"

# CSV header — no qemu_rss for gVisor
echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu_req,node_cpu_pct,node_mem_req,node_mem_pct,host_total_mb,host_used_mb,host_free_mb,host_available_mb,all_pods_ok,stress_cpu_actual,stress_mem_actual" > "$RESULTS_CSV"

# ---------- Pod manifest generator ----------
# Same workload as kata tests: 4 containers, stress-ng
# Total per pod: 450m CPU request, 2048 MiB mem request
# No Pod Overhead for gVisor
gen_manifest() {
  local N=$1
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: maxpod-gvisor-${N}
---
apiVersion: v1
kind: Pod
metadata:
  name: stress-${N}
  namespace: maxpod-gvisor-${N}
spec:
  runtimeClassName: gvisor
  nodeName: ${NODE}
  terminationGracePeriodSeconds: 5
  containers:
  - name: gateway
    image: polinux/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "900M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "150m", memory: "1Gi" }
  - name: config-watcher
    image: polinux/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "200M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: envoy
    image: polinux/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "200M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: wazuh
    image: polinux/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "450M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "100m", memory: "512Mi" }
YAML
}

# ---------- Cleanup function ----------
cleanup() {
  log "Cleaning up all maxpod-gvisor-* namespaces..."
  for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep "^maxpod-gvisor-"); do
    kubectl delete ns "$ns" --force --grace-period=0 &
  done
  wait
  log "Cleanup done."
}

# ---------- Main loop ----------
log "Starting incremental pod deployment..."
STOP_REASON=""
for N in $(seq 1 $MAX_PODS); do
  log "--- Deploying pod $N ---"
  DEPLOY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  gen_manifest "$N" | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

  # Wait for Ready (up to 120s)
  log "Waiting for pod stress-${N} to be Ready..."
  READY=false
  for i in $(seq 1 120); do
    STATUS=$(kubectl get pod "stress-${N}" -n "maxpod-gvisor-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "stress-${N}" -n "maxpod-gvisor-${N}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$STATUS" = "Running" ] && [ "$READY_COND" = "True" ]; then
      READY=true
      break
    fi
    if [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Unknown" ]; then
      log "Pod $N status: $STATUS — stopping."
      STOP_REASON="Pod $N failed with status $STATUS"
      break 2
    fi
    sleep 1
  done

  READY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
  if ! $READY; then
    log "Pod $N did not reach Ready within 120s — stopping."
    STOP_REASON="Pod $N timeout"
  fi

  # Settle period
  log "Settling ${SETTLE_SECS}s for stress workload..."
  sleep "$SETTLE_SECS"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  # Check all pods health
  ALL_OK="OK"
  TOTAL_RESTARTS=0
  for P in $(seq 1 $N); do
    POD_STATUS=$(kubectl get pod "stress-${P}" -n "maxpod-gvisor-${P}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    POD_RESTARTS=$(kubectl get pod "stress-${P}" -n "maxpod-gvisor-${P}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
    R_SUM=0
    for r in $POD_RESTARTS; do R_SUM=$((R_SUM + r)); done
    TOTAL_RESTARTS=$((TOTAL_RESTARTS + R_SUM))
    if [ "$POD_STATUS" != "Running" ] || [ "$R_SUM" -gt 0 ]; then
      ALL_OK="FAIL(pod-${P}:${POD_STATUS}:${R_SUM}restarts)"
      log "WARNING: Pod $P — status=$POD_STATUS restarts=$R_SUM"
    fi
  done

  # kubectl top node
  KT_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A N/A N/A N/A N/A")
  NODE_CPU_REQ=$(echo "$KT_NODE" | awk '{print $2}')
  NODE_CPU_PCT=$(echo "$KT_NODE" | awk '{print $3}')
  NODE_MEM_REQ=$(echo "$KT_NODE" | awk '{print $4}')
  NODE_MEM_PCT=$(echo "$KT_NODE" | awk '{print $5}')

  # Host-level metrics via SSH
  FREE_OUT=$(ssh_node "free -m | grep Mem" || echo "Mem: 0 0 0 0 0 0")
  HOST_TOTAL=$(echo "$FREE_OUT" | awk '{print $2}')
  HOST_USED=$(echo "$FREE_OUT" | awk '{print $3}')
  HOST_FREE=$(echo "$FREE_OUT" | awk '{print $4}')
  HOST_AVAIL=$(echo "$FREE_OUT" | awk '{print $7}')

  # Actual CPU/mem usage
  STRESS_CPU=$(kubectl top pod -n "maxpod-gvisor-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$3} END {gsub(/m/,"",sum); printf "%sm", sum}' || echo "N/A")
  STRESS_MEM=$(kubectl top pod -n "maxpod-gvisor-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$4} END {printf "%s", sum}' || echo "N/A")

  log "Pod $N metrics: status=$ALL_OK restarts=$TOTAL_RESTARTS host_avail=${HOST_AVAIL}MiB stress_cpu=$STRESS_CPU stress_mem=$STRESS_MEM"

  echo "${N},${DEPLOY_TIME},${READY_TIME},${SETTLE_TIME},Running,${TOTAL_RESTARTS},${NODE_CPU_REQ},${NODE_CPU_PCT},${NODE_MEM_REQ},${NODE_MEM_PCT},${HOST_TOTAL},${HOST_USED},${HOST_FREE},${HOST_AVAIL},${ALL_OK},${STRESS_CPU},${STRESS_MEM}" >> "$RESULTS_CSV"

  # Stop if restarts detected
  if [ "$TOTAL_RESTARTS" -gt 0 ]; then
    STOP_REASON="Restarts detected after pod $N: total=$TOTAL_RESTARTS"
    log "STOP: $STOP_REASON"
    break
  fi

  if ! $READY; then
    break
  fi

  log "Pod $N stable. Continuing..."
done

if [ -z "$STOP_REASON" ]; then
  STOP_REASON="Reached max pod limit ($MAX_PODS)"
fi

log ""
log "=== TEST COMPLETE ==="
log "Stop reason: $STOP_REASON"
log ""
log "Results saved to $RESULTS_CSV"
log ""

# Print summary table
log "=== SUMMARY TABLE ==="
column -t -s',' "$RESULTS_CSV" 2>/dev/null | tee -a "$LOG_FILE" || cat "$RESULTS_CSV" | tee -a "$LOG_FILE"

log ""
log "Cleaning up..."
cleanup
log "Done."
