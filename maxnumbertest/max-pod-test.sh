#!/bin/bash
# max-pod-test.sh — Maximum Stable Pod Count Test for kata-qemu on m8i.2xlarge
# Deploys pods one-at-a-time, collects metrics after each, stops on failure or safety limit.

set -euo pipefail

TARGET_NODE="ip-172-31-17-237.us-west-2.compute.internal"
RUNTIME_CLASS="kata-qemu"
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_FILE="${RESULTS_DIR}/results.csv"
LOG_FILE="${RESULTS_DIR}/test.log"
MAX_PODS=20           # hard upper bound (safety)
SETTLE_TIME=60        # seconds to wait after pod Ready
START_TIMEOUT=180     # 3 minutes for pod to become Ready
MEM_SAFETY_MB=2048    # stop if host MemAvailable < 2 GiB

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ---------- CSV header ----------
cat > "$CSV_FILE" <<'HDR'
pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,kt_cpu_gateway,kt_mem_gateway,kt_cpu_configwatcher,kt_mem_configwatcher,kt_cpu_envoy,kt_mem_envoy,kt_cpu_wazuh,kt_mem_wazuh,node_cpu_req,node_cpu_pct,node_mem_req,node_mem_pct,qemu_rss_mb,host_total_mb,host_used_mb,host_free_mb,host_available_mb,all_pods_ok
HDR

# ---------- Helper: generate pod manifest ----------
gen_manifest() {
  local N=$1
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: maxpod-${N}
---
apiVersion: v1
kind: Pod
metadata:
  name: sandbox-${N}
  namespace: maxpod-${N}
  labels:
    app: maxpod-test
    pod-num: "${N}"
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  nodeSelector:
    kubernetes.io/hostname: ${TARGET_NODE}
    workload-type: kata
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
  - key: kata-oversell
    operator: Exists
    effect: NoSchedule
  terminationGracePeriodSeconds: 5
  containers:
  - name: gateway
    image: nginx:1.27
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "150m", memory: "1Gi" }
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 15
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 5
      timeoutSeconds: 3
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh","-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock bs=1M count=200 2>/dev/null
      while true; do sleep 30; done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: envoy
    image: busybox:1.36
    command: ["/bin/sh","-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock2 bs=1M count=200 2>/dev/null
      i=0; while true; do i=\$((i+1)); if [ \$((i%10000)) -eq 0 ]; then sleep 0.01; fi; done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh","-c"]
    args:
    - |
      dd if=/dev/urandom of=/dev/shm/memblock3 bs=1M count=400 2>/dev/null
      while true; do find / -maxdepth 3 -type f > /dev/null 2>&1; sleep 5; done
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "100m", memory: "512Mi" }
YAML
}

# ---------- Helper: wait for pod Ready ----------
wait_ready() {
  local NS=$1 POD=$2 TIMEOUT=$3
  local deadline=$((SECONDS + TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    local phase
    phase=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$phase" = "Running" ]; then
      local ready
      ready=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
      if [ "$ready" = "True" ]; then
        return 0
      fi
    elif [ "$phase" = "Failed" ]; then
      return 1
    fi
    # Check for scheduling failures
    local sched_reason
    sched_reason=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || echo "")
    if [ "$sched_reason" = "Unschedulable" ]; then
      log "Pod $POD unschedulable: $(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null)"
      return 2
    fi
    sleep 5
  done
  return 1  # timeout
}

# ---------- Helper: count total restarts across ALL test pods ----------
count_all_restarts() {
  local total=0
  for i in $(seq 1 "$1"); do
    local r
    r=$(kubectl get pod "sandbox-${i}" -n "maxpod-${i}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
    for v in $r; do total=$((total + v)); done
  done
  echo "$total"
}

# ---------- Helper: check all pods Running ----------
check_all_running() {
  local count=$1
  for i in $(seq 1 "$count"); do
    local phase
    phase=$(kubectl get pod "sandbox-${i}" -n "maxpod-${i}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$phase" != "Running" ]; then
      echo "FAIL:sandbox-${i}=${phase}"
      return 1
    fi
  done
  echo "OK"
  return 0
}

# ---------- Helper: get pod restarts for a specific pod ----------
get_pod_restarts() {
  local NS=$1 POD=$2
  local total=0
  local r
  r=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
  for v in $r; do total=$((total + v)); done
  echo "$total"
}

# ========== MAIN ==========
log "===== Maximum Stable Pod Count Test ====="
log "Target node: ${TARGET_NODE}"
log "RuntimeClass: ${RUNTIME_CLASS}"
log "Settle time: ${SETTLE_TIME}s | Start timeout: ${START_TIMEOUT}s"

# Baseline
log "--- Baseline before any test pods ---"
kubectl top node "$TARGET_NODE" 2>&1 | tee -a "$LOG_FILE"
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c "free -m" 2>&1 | tee -a "$LOG_FILE"

BASELINE_RESTARTS=0
MAX_STABLE=0
STOP_REASON=""

for N in $(seq 1 $MAX_PODS); do
  log "====== Deploying pod ${N} ======"
  DEPLOY_TS=$(date '+%Y-%m-%d %H:%M:%S')

  # Deploy
  gen_manifest "$N" | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

  # Wait for Ready
  log "Waiting for sandbox-${N} to become Ready (timeout ${START_TIMEOUT}s)..."
  WAIT_START=$SECONDS
  if ! wait_ready "maxpod-${N}" "sandbox-${N}" "$START_TIMEOUT"; then
    RC=$?
    READY_TS=$(date '+%Y-%m-%d %H:%M:%S')
    log "STOP: Pod sandbox-${N} failed to reach Ready (rc=${RC})"
    kubectl get pod "sandbox-${N}" -n "maxpod-${N}" -o wide 2>&1 | tee -a "$LOG_FILE"
    kubectl describe pod "sandbox-${N}" -n "maxpod-${N}" 2>&1 | tail -30 | tee -a "$LOG_FILE"
    if [ "${RC}" = "2" ]; then
      STOP_REASON="Pod ${N} unschedulable (Insufficient resources)"
    else
      STOP_REASON="Pod ${N} failed to start within ${START_TIMEOUT}s"
    fi
    # Clean up the failed pod's namespace
    kubectl delete namespace "maxpod-${N}" --wait=false 2>/dev/null || true
    break
  fi
  WAIT_ELAPSED=$((SECONDS - WAIT_START))
  READY_TS=$(date '+%Y-%m-%d %H:%M:%S')
  log "sandbox-${N} Ready in ${WAIT_ELAPSED}s"

  # Settle
  log "Settling for ${SETTLE_TIME}s..."
  sleep "$SETTLE_TIME"
  SETTLE_TS=$(date '+%Y-%m-%d %H:%M:%S')

  # ---------- Collect metrics ----------
  log "--- Metrics after pod ${N} settled ---"

  # kubectl top pod for all test pods
  log "kubectl top pod (all test namespaces):"
  KT_POD_OUTPUT=""
  for i in $(seq 1 "$N"); do
    local_out=$(kubectl top pod "sandbox-${i}" -n "maxpod-${i}" --containers 2>/dev/null || echo "error")
    KT_POD_OUTPUT+="${local_out}"$'\n'
  done
  echo "$KT_POD_OUTPUT" | tee -a "$LOG_FILE"

  # Current pod's container metrics
  KT_CURRENT=$(kubectl top pod "sandbox-${N}" -n "maxpod-${N}" --containers 2>/dev/null || echo "")
  KT_GW_CPU=$(echo "$KT_CURRENT" | grep "gateway" | awk '{print $3}' || echo "N/A")
  KT_GW_MEM=$(echo "$KT_CURRENT" | grep "gateway" | awk '{print $4}' || echo "N/A")
  KT_CW_CPU=$(echo "$KT_CURRENT" | grep "config-watcher" | awk '{print $3}' || echo "N/A")
  KT_CW_MEM=$(echo "$KT_CURRENT" | grep "config-watcher" | awk '{print $4}' || echo "N/A")
  KT_ENV_CPU=$(echo "$KT_CURRENT" | grep "envoy" | awk '{print $3}' || echo "N/A")
  KT_ENV_MEM=$(echo "$KT_CURRENT" | grep "envoy" | awk '{print $4}' || echo "N/A")
  KT_WAZ_CPU=$(echo "$KT_CURRENT" | grep "wazuh" | awk '{print $3}' || echo "N/A")
  KT_WAZ_MEM=$(echo "$KT_CURRENT" | grep "wazuh" | awk '{print $4}' || echo "N/A")

  # kubectl top node
  log "kubectl top node:"
  KT_NODE=$(kubectl top node "$TARGET_NODE" 2>/dev/null || echo "error")
  echo "$KT_NODE" | tee -a "$LOG_FILE"
  NODE_CPU_REQ=$(echo "$KT_NODE" | tail -1 | awk '{print $2}' || echo "N/A")
  NODE_CPU_PCT=$(echo "$KT_NODE" | tail -1 | awk '{print $3}' || echo "N/A")
  NODE_MEM_REQ=$(echo "$KT_NODE" | tail -1 | awk '{print $4}' || echo "N/A")
  NODE_MEM_PCT=$(echo "$KT_NODE" | tail -1 | awk '{print $5}' || echo "N/A")

  # QEMU RSS via hostmon
  log "QEMU RSS (host):"
  QEMU_RSS=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c \
    "ps aux | grep '[q]emu-system' | awk '{sum+=\$6} END {printf \"%.0f\", sum/1024}'" 2>/dev/null || echo "N/A")
  log "Total QEMU RSS: ${QEMU_RSS} MB"

  # QEMU per-process detail
  log "QEMU per-process:"
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c \
    "ps aux | grep '[q]emu-system' | awk '{printf \"PID=%s RSS=%.0fMB\\n\", \$2, \$6/1024}'" 2>&1 | tee -a "$LOG_FILE"

  # Host free -m
  log "Host free -m:"
  HOST_MEM=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c "free -m" 2>/dev/null || echo "error")
  echo "$HOST_MEM" | tee -a "$LOG_FILE"
  HOST_TOTAL=$(echo "$HOST_MEM" | grep "^Mem:" | awk '{print $2}' || echo "N/A")
  HOST_USED=$(echo "$HOST_MEM" | grep "^Mem:" | awk '{print $3}' || echo "N/A")
  HOST_FREE=$(echo "$HOST_MEM" | grep "^Mem:" | awk '{print $4}' || echo "N/A")
  HOST_AVAIL=$(echo "$HOST_MEM" | grep "^Mem:" | awk '{print $7}' || echo "N/A")

  # Check all pods still Running
  ALL_OK=$(check_all_running "$N" || true)
  log "All pods check: ${ALL_OK}"

  # Check restarts
  CURRENT_RESTARTS=$(count_all_restarts "$N")
  log "Total restarts across all test pods: ${CURRENT_RESTARTS}"

  # Get this pod's restarts specifically
  POD_RESTARTS=$(get_pod_restarts "maxpod-${N}" "sandbox-${N}")

  # ---------- Write CSV row ----------
  echo "${N},${DEPLOY_TS},${READY_TS},${SETTLE_TS},Running,${POD_RESTARTS},${KT_GW_CPU},${KT_GW_MEM},${KT_CW_CPU},${KT_CW_MEM},${KT_ENV_CPU},${KT_ENV_MEM},${KT_WAZ_CPU},${KT_WAZ_MEM},${NODE_CPU_REQ},${NODE_CPU_PCT},${NODE_MEM_REQ},${NODE_MEM_PCT},${QEMU_RSS},${HOST_TOTAL},${HOST_USED},${HOST_FREE},${HOST_AVAIL},${ALL_OK}" >> "$CSV_FILE"

  # ---------- Stop conditions ----------
  if [ "$ALL_OK" != "OK" ]; then
    log "STOP: Some pods no longer Running: ${ALL_OK}"
    STOP_REASON="Existing pod crashed/failed after deploying pod ${N}: ${ALL_OK}"
    break
  fi

  if [ "$CURRENT_RESTARTS" -gt "$BASELINE_RESTARTS" ]; then
    NEW_RESTARTS=$((CURRENT_RESTARTS - BASELINE_RESTARTS))
    log "STOP: ${NEW_RESTARTS} new restart(s) detected"
    STOP_REASON="${NEW_RESTARTS} container restart(s) detected after deploying pod ${N}"
    break
  fi

  if [ "$HOST_AVAIL" != "N/A" ] && [ "$HOST_AVAIL" -lt "$MEM_SAFETY_MB" ] 2>/dev/null; then
    log "STOP: Host MemAvailable=${HOST_AVAIL}MB < safety margin ${MEM_SAFETY_MB}MB"
    STOP_REASON="Host MemAvailable (${HOST_AVAIL}MB) below safety margin (${MEM_SAFETY_MB}MB)"
    break
  fi

  MAX_STABLE=$N
  log "Pod ${N} stable. MAX_STABLE=${MAX_STABLE}"
done

# ---------- Final summary ----------
log ""
log "===== TEST COMPLETE ====="
log "Maximum stable pod count: ${MAX_STABLE}"
log "Stop reason: ${STOP_REASON:-None (reached hard limit)}"
log ""

# Final snapshot
log "--- Final state ---"
for i in $(seq 1 "$MAX_STABLE"); do
  kubectl get pod "sandbox-${i}" -n "maxpod-${i}" -o wide 2>/dev/null | tee -a "$LOG_FILE"
done
kubectl top node "$TARGET_NODE" 2>&1 | tee -a "$LOG_FILE"
kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c "free -m" 2>&1 | tee -a "$LOG_FILE"

log "Results CSV: ${CSV_FILE}"
log "Full log: ${LOG_FILE}"
