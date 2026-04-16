#!/usr/bin/env bash
# max-pod-test-graviton-gvisor-efs.sh — Max pod density test with FULL CPU + memory pressure
# gVisor (runsc) on m7g.2xlarge (Graviton, 8 vCPU, 32 GiB) with EFS PVC per pod
#
# Same workload as stress-2x-gvisor for fair comparison, plus EFS mount.
#
# Usage: ./max-pod-test-graviton-gvisor-efs.sh [target_node]
set -euo pipefail

NODE="${1:?Usage: $0 <node>}"
RUNTIME="gvisor"
MAX_PODS=30           # gVisor should support more pods (no VM overhead)
SETTLE_SECS=90        # same settle time as other tests
RESULTS_CSV="results-graviton-gvisor-efs.csv"
LOG_FILE="test-graviton-gvisor-efs.log"
EFS_SC="efs-sc"       # EFS StorageClass name

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

# ---------- Pre-flight ----------
log "=== Max Pod Full-Load Test: gVisor (runsc) on Graviton $NODE with EFS ==="
log "Checking node..."
kubectl get node "$NODE" -o jsonpath='{.metadata.name} {.status.allocatable.cpu} cpu, {.status.allocatable.memory} mem' | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

ALLOC_CPU=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}' | sed 's/m//')
ALLOC_MEM_KI=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//')
ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
NODE_ARCH=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')
NODE_TYPE=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
log "Node: ${NODE_TYPE} (${NODE_ARCH}), allocatable: ${ALLOC_CPU}m CPU, ${ALLOC_MEM_MI} MiB memory"

# Baseline
log "Collecting baseline..."
BASELINE_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A")
log "Baseline kubectl top node: $BASELINE_NODE"

NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
ssh_node() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$NODE_IP" "$@" 2>/dev/null; }
BASELINE_FREE=$(ssh_node "free -m | grep Mem" || echo "N/A")
log "Baseline free -m: $BASELINE_FREE"

# CSV header
echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu_req,node_cpu_pct,node_mem_req,node_mem_pct,host_total_mb,host_used_mb,host_free_mb,host_available_mb,all_pods_ok,stress_cpu_actual,stress_mem_actual,efs_mount_ok" > "$RESULTS_CSV"

# ---------- Pod manifest generator ----------
# Same workload as stress-2x-gvisor: 4 containers, stress-ng
# Total per pod: 450m CPU request, 2048 MiB mem request
# Plus: EFS PVC mounted to each pod
gen_manifest() {
  local N=$1
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: maxpod-graviton-gvisor-efs-${N}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-data-${N}
  namespace: maxpod-graviton-gvisor-efs-${N}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${EFS_SC}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: stress-${N}
  namespace: maxpod-graviton-gvisor-efs-${N}
spec:
  runtimeClassName: gvisor
  nodeName: ${NODE}
  terminationGracePeriodSeconds: 5
  tolerations:
  - key: gvisor
    operator: Equal
    value: "true"
    effect: NoSchedule
  volumes:
  - name: efs-vol
    persistentVolumeClaim:
      claimName: efs-data-${N}
  containers:
  - name: gateway
    image: ghcr.io/colinianking/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "900M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "150m", memory: "1Gi" }
    volumeMounts:
    - name: efs-vol
      mountPath: /data
  - name: config-watcher
    image: ghcr.io/colinianking/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "200M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: envoy
    image: ghcr.io/colinianking/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "200M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: wazuh
    image: ghcr.io/colinianking/stress-ng:latest
    command: ["stress-ng"]
    args: ["--cpu", "1", "--cpu-load", "95", "--vm", "1", "--vm-bytes", "450M", "--vm-keep", "--timeout", "0"]
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "100m", memory: "512Mi" }
YAML
}

# ---------- Cleanup function ----------
cleanup() {
  log "Cleaning up all maxpod-graviton-gvisor-efs-* namespaces..."
  for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep "^maxpod-graviton-gvisor-efs-"); do
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

  # Wait for PVC to bind (up to 60s)
  log "Waiting for EFS PVC to bind..."
  for i in $(seq 1 60); do
    PVC_STATUS=$(kubectl get pvc "efs-data-${N}" -n "maxpod-graviton-gvisor-efs-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$PVC_STATUS" = "Bound" ]; then
      log "EFS PVC bound."
      break
    fi
    sleep 1
  done

  # Wait for Ready (up to 180s — EFS mount may take longer)
  log "Waiting for pod stress-${N} to be Ready..."
  READY=false
  for i in $(seq 1 180); do
    STATUS=$(kubectl get pod "stress-${N}" -n "maxpod-graviton-gvisor-efs-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "stress-${N}" -n "maxpod-graviton-gvisor-efs-${N}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
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

  # Settle period
  log "Settling ${SETTLE_SECS}s for stress workload..."
  sleep "$SETTLE_SECS"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  # Check all pods health
  ALL_OK="OK"
  TOTAL_RESTARTS=0
  for P in $(seq 1 $N); do
    POD_STATUS=$(kubectl get pod "stress-${P}" -n "maxpod-graviton-gvisor-efs-${P}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    POD_RESTARTS=$(kubectl get pod "stress-${P}" -n "maxpod-graviton-gvisor-efs-${P}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
    R_SUM=0
    for r in $POD_RESTARTS; do R_SUM=$((R_SUM + r)); done
    TOTAL_RESTARTS=$((TOTAL_RESTARTS + R_SUM))
    if [ "$POD_STATUS" != "Running" ] || [ "$R_SUM" -gt 0 ]; then
      ALL_OK="FAIL(pod-${P}:${POD_STATUS}:${R_SUM}restarts)"
      log "WARNING: Pod $P — status=$POD_STATUS restarts=$R_SUM"
    fi
  done

  # Check EFS mount on latest pod
  EFS_OK="OK"
  kubectl exec "stress-${N}" -n "maxpod-graviton-gvisor-efs-${N}" -c gateway -- df -h /data > /dev/null 2>&1 || EFS_OK="FAIL"
  log "EFS mount check on pod $N: $EFS_OK"

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
  STRESS_CPU=$(kubectl top pod -n "maxpod-graviton-gvisor-efs-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$3} END {gsub(/m/,"",sum); printf "%sm", sum}' || echo "N/A")
  STRESS_MEM=$(kubectl top pod -n "maxpod-graviton-gvisor-efs-${N}" --containers --no-headers 2>/dev/null | awk '{sum+=$4} END {printf "%s", sum}' || echo "N/A")

  log "Pod $N metrics: status=$ALL_OK restarts=$TOTAL_RESTARTS host_avail=${HOST_AVAIL}MiB stress_cpu=$STRESS_CPU stress_mem=$STRESS_MEM efs=$EFS_OK"

  echo "${N},${DEPLOY_TIME},${READY_TIME},${SETTLE_TIME},Running,${TOTAL_RESTARTS},${NODE_CPU_REQ},${NODE_CPU_PCT},${NODE_MEM_REQ},${NODE_MEM_PCT},${HOST_TOTAL},${HOST_USED},${HOST_FREE},${HOST_AVAIL},${ALL_OK},${STRESS_CPU},${STRESS_MEM},${EFS_OK}" >> "$RESULTS_CSV"

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
