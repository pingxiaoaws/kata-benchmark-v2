#!/usr/bin/env bash
# max-pod-test-fullload-fc.sh — Max pod density with FULL CPU + memory pressure
# kata-fc on m7g.metal (64 vCPU, 256 GiB, Graviton3 bare metal)
#
# 4 containers per pod running stress-ng (same config as kata-qemu stress tests)
# Guaranteed QoS (requests == limits)

NODE="${1:-ip-172-31-22-115.us-west-2.compute.internal}"
RUNTIME="kata-fc"
MAX_PODS=100          # theoretical ~91, give room
SETTLE_SECS=90        # settle for stress workload
RESULTS_CSV="results-fullload.csv"
LOG_FILE="test-fullload.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

# ---------- Pre-flight ----------
: > "$LOG_FILE"
log "=== Max Pod Full-Load Test: $RUNTIME on $NODE ==="
log "Instance: m7g.metal (64 vCPU, 256 GiB, Graviton3, bare metal)"
log "Runtime: $RUNTIME, Overhead: cpu=250m mem=130Mi"
log "Pod: 4 containers, 450m/2048Mi + overhead = 700m/2178Mi per pod"
log "Theoretical max: CPU=63770/700=~91, MEM=248847/2178=~114"

log "Checking node..."
kubectl get node "$NODE" -o jsonpath='{.metadata.name} cpu={.status.allocatable.cpu} mem={.status.allocatable.memory}' | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

ALLOC_CPU=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}' | sed 's/m//')
ALLOC_MEM_KI=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//')
ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
log "Allocatable: ${ALLOC_CPU}m CPU, ${ALLOC_MEM_MI} MiB memory"

# Baseline
BASELINE_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A")
log "Baseline top node: $BASELINE_NODE"

# CSV header
echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu,node_cpu_pct,node_mem,node_mem_pct,all_pods_ok,stress_cpu,stress_mem" > "$RESULTS_CSV"

# ---------- Pod manifest generator ----------
gen_manifest() {
  local N=$1
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: maxpod-fc-${N}
---
apiVersion: v1
kind: Pod
metadata:
  name: stress-${N}
  namespace: maxpod-fc-${N}
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
  log "Cleaning up all maxpod-fc-* namespaces..."
  for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep '^maxpod-fc-'); do
    kubectl delete ns "$ns" --force --grace-period=0 2>/dev/null &
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

  # Wait for Ready (up to 180s — first pod may need image pull on arm64)
  log "Waiting for pod stress-${N} to be Ready..."
  READY=false
  for i in $(seq 1 180); do
    STATUS=$(kubectl get pod "stress-${N}" -n "maxpod-fc-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "stress-${N}" -n "maxpod-fc-${N}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
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
    log "Pod $N did not reach Ready within 180s — stopping."
    STOP_REASON="Pod $N timeout"
  fi

  # Settle period — let stress-ng ramp up
  log "Settling ${SETTLE_SECS}s for stress workload..."
  sleep "$SETTLE_SECS"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  # Check all pods health
  ALL_OK="OK"
  TOTAL_RESTARTS=0
  for P in $(seq 1 $N); do
    POD_STATUS=$(kubectl get pod "stress-${P}" -n "maxpod-fc-${P}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    POD_RESTARTS=$(kubectl get pod "stress-${P}" -n "maxpod-fc-${P}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
    R_SUM=0
    for r in $POD_RESTARTS; do R_SUM=$((R_SUM + r)); done
    TOTAL_RESTARTS=$((TOTAL_RESTARTS + R_SUM))
    if [ "$POD_STATUS" != "Running" ] || [ "$R_SUM" -gt 0 ]; then
      ALL_OK="FAIL(pod-${P}:${POD_STATUS}:${R_SUM}r)"
      log "WARNING: Pod $P — status=$POD_STATUS restarts=$R_SUM"
    fi
  done

  # kubectl top node
  KT_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A N/A N/A N/A N/A")
  NODE_CPU=$(echo "$KT_NODE" | awk '{print $2}')
  NODE_CPU_PCT=$(echo "$KT_NODE" | awk '{print $3}')
  NODE_MEM=$(echo "$KT_NODE" | awk '{print $4}')
  NODE_MEM_PCT=$(echo "$KT_NODE" | awk '{print $5}')

  # stress-ng actual usage for latest pod
  STRESS_CPU=$(kubectl top pod -n "maxpod-fc-${N}" --containers --no-headers 2>/dev/null | awk '{gsub(/m/,"",$3); sum+=$3} END {printf "%dm", sum}' || echo "N/A")
  STRESS_MEM=$(kubectl top pod -n "maxpod-fc-${N}" --containers --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$4); sum+=$4} END {printf "%dMi", sum}' || echo "N/A")

  log "Pod $N: status=$ALL_OK restarts=$TOTAL_RESTARTS node_cpu=$NODE_CPU($NODE_CPU_PCT) node_mem=$NODE_MEM($NODE_MEM_PCT) stress_cpu=$STRESS_CPU stress_mem=$STRESS_MEM"

  echo "${N},${DEPLOY_TIME},${READY_TIME},${SETTLE_TIME},Running,${TOTAL_RESTARTS},${NODE_CPU},${NODE_CPU_PCT},${NODE_MEM},${NODE_MEM_PCT},${ALL_OK},${STRESS_CPU},${STRESS_MEM}" >> "$RESULTS_CSV"

  # Stop if restarts detected
  if [ "$TOTAL_RESTARTS" -gt 0 ]; then
    STOP_REASON="Restarts detected after pod $N: total=$TOTAL_RESTARTS"
    log "STOP: $STOP_REASON"
    break
  fi

  if [ "$READY" = false ]; then
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
log "Max stable pods: $((N - (TOTAL_RESTARTS > 0 ? 1 : 0)))"
log ""
log "Results: $RESULTS_CSV"

# Print summary table
log "=== SUMMARY TABLE ==="
column -t -s',' "$RESULTS_CSV" 2>/dev/null | tee -a "$LOG_FILE" || cat "$RESULTS_CSV" | tee -a "$LOG_FILE"

log ""
log "Cleaning up..."
cleanup
log "Done."
