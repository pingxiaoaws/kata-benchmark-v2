#!/usr/bin/env bash
# max-pod-test-fullload.sh — Max pod density test with FULL CPU + memory pressure
# kata-qemu on m8i.4xlarge (16 vCPU, 64 GiB)
#
# Difference from v1: every container runs stress-ng to saturate both CPU and memory
# to their request limits, simulating worst-case production load.
#
# Usage: ./max-pod-test-fullload.sh [target_node]
set -euo pipefail

NODE="${1:?Usage: $0 <node> [runtime]}"
RUNTIME="${2:-kata-qemu}"
MAX_PODS=25           # upper bound, will stop on failure
SETTLE_SECS=90        # longer settle for stress workload
RESULTS_CSV="results-fullload-${RUNTIME}.csv"
LOG_FILE="test-fullload-${RUNTIME}.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

# ---------- Pre-flight ----------
log "=== Max Pod Full-Load Test: $RUNTIME on $NODE ==="
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

# SSH to node for host-level metrics
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
ssh_node() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$NODE_IP" "$@" 2>/dev/null; }
BASELINE_FREE=$(ssh_node "free -m | grep Mem" || echo "N/A")
log "Baseline free -m: $BASELINE_FREE"

# CSV header
echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu_req,node_cpu_pct,node_mem_req,node_mem_pct,qemu_rss_mb,host_total_mb,host_used_mb,host_free_mb,host_available_mb,all_pods_ok,stress_cpu_actual,stress_mem_actual" > "$RESULTS_CSV"

# ---------- Pod manifest generator ----------
# Each pod: 4 containers, all running stress-ng
#   gateway:        150m CPU, 1Gi mem  → stress 1 cpu worker + 900M vm worker
#   config-watcher: 100m CPU, 256Mi    → stress 1 cpu + 200M vm
#   envoy:          100m CPU, 256Mi    → stress 1 cpu + 200M vm
#   wazuh:          100m CPU, 512Mi    → stress 1 cpu + 450M vm
# Total per pod: 450m CPU request, 2048 MiB mem request
# + overhead: 100m CPU, 250 MiB mem → scheduling: 550m CPU, 2298 MiB
gen_manifest() {
  local N=$1
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: maxpod-${RUNTIME}-${N}
---
apiVersion: v1
kind: Pod
metadata:
  name: stress-${N}
  namespace: maxpod-${RUNTIME}-${N}
spec:
  runtimeClassName: ${RUNTIME}
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
  log "Cleaning up all maxpod-${RUNTIME}-* namespaces..."
  for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep "^maxpod-${RUNTIME}-"); do
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

  # Wait for Ready (up to 120s — stress-ng image may need pull)
  log "Waiting for pod stress-${N} to be Ready..."
  READY=false
  for i in $(seq 1 120); do
    STATUS=$(kubectl get pod "stress-${N}" -n "maxpod-${RUNTIME}-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "stress-${N}" -n "maxpod-${RUNTIME}-${N}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
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
    # Still collect metrics before breaking
  fi

  # Settle period — let stress-ng ramp up
  log "Settling ${SETTLE_SECS}s for stress workload..."
  sleep "$SETTLE_SECS"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  # Check all pods health
  ALL_OK="OK"
  TOTAL_RESTARTS=0
  for P in $(seq 1 $N); do
    POD_STATUS=$(kubectl get pod "stress-${P}" -n "maxpod-${RUNTIME}-${P}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    POD_RESTARTS=$(kubectl get pod "stress-${P}" -n "maxpod-${RUNTIME}-${P}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
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
  QEMU_RSS=$(ssh_node "ps aux | grep 'qemu-system' | grep -v grep | awk '{sum+=\$6} END {printf \"%.0f\", sum/1024}'" || echo "N/A")
  FREE_OUT=$(ssh_node "free -m | grep Mem" || echo "Mem: 0 0 0 0 0 0")
  HOST_TOTAL=$(echo "$FREE_OUT" | awk '{print $2}')
  HOST_USED=$(echo "$FREE_OUT" | awk '{print $3}')
  HOST_FREE=$(echo "$FREE_OUT" | awk '{print $4}')
  HOST_AVAIL=$(echo "$FREE_OUT" | awk '{print $7}')

  # Measure actual CPU usage per pod via kubectl top
  STRESS_CPU=$(kubectl top pod -n "maxpod-${RUNTIME}-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$3} END {gsub(/m/,"",sum); printf "%sm", sum}' || echo "N/A")
  STRESS_MEM=$(kubectl top pod -n "maxpod-${RUNTIME}-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$4} END {printf "%s", sum}' || echo "N/A")

  log "Pod $N metrics: status=$ALL_OK restarts=$TOTAL_RESTARTS qemu_rss=${QEMU_RSS}MiB host_avail=${HOST_AVAIL}MiB stress_cpu=$STRESS_CPU stress_mem=$STRESS_MEM"

  echo "${N},${DEPLOY_TIME},${READY_TIME},${SETTLE_TIME},Running,${TOTAL_RESTARTS},${NODE_CPU_REQ},${NODE_CPU_PCT},${NODE_MEM_REQ},${NODE_MEM_PCT},${QEMU_RSS},${HOST_TOTAL},${HOST_USED},${HOST_FREE},${HOST_AVAIL},${ALL_OK},${STRESS_CPU},${STRESS_MEM}" >> "$RESULTS_CSV"

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
