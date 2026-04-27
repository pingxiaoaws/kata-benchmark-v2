#!/usr/bin/env bash
# max-pod-test-fullload-fc.sh — Max pod density with FULL CPU + memory pressure
# kata-fc on m7g.metal (64 vCPU, 256 GiB, Graviton3 bare metal)
#
# Uses busybox (single-layer image) because kata-fc devmapper snapshotter
# cannot unpack multi-layer images (alpine, nginx, stress-ng all fail).
# CPU stress: while true; do :; done (burns to cgroup CPU limit)
# Memory stress: dd to /dev/shm (allocates real resident memory)

NODE="${1:-ip-172-31-42-51.us-west-2.compute.internal}"
RUNTIME="kata-fc"
MAX_PODS=100
SETTLE_SECS=60
RESULTS_CSV="results-fullload-m7g-ebs.csv"
LOG_FILE="test-fullload-m7g-ebs.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

: > "$LOG_FILE"
log "=== Max Pod Full-Load Test: $RUNTIME on m7g.metal ==="
log "64 vCPU, 256 GiB, Graviton3, bare metal, aarch64"
log "Runtime: $RUNTIME, Overhead: cpu=250m mem=130Mi"
log "Pod: 4 containers (busybox), 450m/2048Mi + overhead = 700m/2178Mi"
log "Theoretical max: CPU=63770/700=~91, MEM=248847/2178=~114"
log "Image: busybox:1.36 (kata-fc devmapper only supports single-layer)"

log "Checking node..."
kubectl get node "$NODE" -o jsonpath='{.metadata.name} cpu={.status.allocatable.cpu} mem={.status.allocatable.memory}' | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

ALLOC_CPU=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}' | sed 's/m//')
ALLOC_MEM_KI=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//')
ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
log "Allocatable: ${ALLOC_CPU}m CPU, ${ALLOC_MEM_MI} MiB memory"

BASELINE_NODE=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A")
log "Baseline top node: $BASELINE_NODE"

echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu,node_cpu_pct,node_mem,node_mem_pct,all_pods_ok,stress_cpu,stress_mem" > "$RESULTS_CSV"

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
  tolerations:
  - key: kata-dedicated
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  - name: gateway
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/zero of=/dev/shm/gateway bs=1M count=900 2>/dev/null
      while true; do :; done
    resources:
      requests: { cpu: "150m", memory: "1Gi" }
      limits:   { cpu: "150m", memory: "1Gi" }
  - name: config-watcher
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/zero of=/dev/shm/cfgwatch bs=1M count=200 2>/dev/null
      while true; do :; done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: envoy
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/zero of=/dev/shm/envoy bs=1M count=200 2>/dev/null
      while true; do :; done
    resources:
      requests: { cpu: "100m", memory: "256Mi" }
      limits:   { cpu: "100m", memory: "256Mi" }
  - name: wazuh
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      dd if=/dev/zero of=/dev/shm/wazuh bs=1M count=450 2>/dev/null
      while true; do :; done
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "100m", memory: "512Mi" }
YAML
}

cleanup() {
  log "Cleaning up all maxpod-fc-* namespaces..."
  for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep '^maxpod-fc-'); do
    kubectl delete ns "$ns" --force --grace-period=0 2>/dev/null &
  done
  wait
  log "Cleanup done."
}

log "Starting incremental pod deployment..."
STOP_REASON=""
LAST_STABLE=0

for N in $(seq 1 $MAX_PODS); do
  log "--- Deploying pod $N ---"
  DEPLOY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  gen_manifest "$N" | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

  log "Waiting for pod stress-${N} to be Ready (max 300s)..."
  READY=false
  for i in $(seq 1 300); do
    STATUS=$(kubectl get pod "stress-${N}" -n "maxpod-fc-${N}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "stress-${N}" -n "maxpod-fc-${N}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$STATUS" = "Running" ] && [ "$READY_COND" = "True" ]; then
      READY=true
      break
    fi
    if [ "$STATUS" = "Failed" ]; then
      log "Pod $N status: Failed — stopping."
      STOP_REASON="Pod $N failed"
      break 2
    fi
    # Check Unschedulable after 60s
    if [ "$i" -gt 60 ]; then
      SCHED_MSG=$(kubectl get pod "stress-${N}" -n "maxpod-fc-${N}" -o jsonpath='{.status.conditions[?(@.reason=="Unschedulable")].message}' 2>/dev/null || true)
      if [ -n "$SCHED_MSG" ]; then
        log "UNSCHEDULABLE: $SCHED_MSG"
        STOP_REASON="Pod $N unschedulable: $SCHED_MSG"
        break 2
      fi
    fi
    sleep 1
  done

  READY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
  if [ "$READY" = false ] && [ -z "$STOP_REASON" ]; then
    log "Pod $N not Ready within 300s — continuing anyway"
  fi

  log "Settling ${SETTLE_SECS}s..."
  sleep "$SETTLE_SECS"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')

  # Health check all pods
  ALL_OK="OK"
  TOTAL_RESTARTS=0
  for P in $(seq 1 $N); do
    PS=$(kubectl get pod "stress-${P}" -n "maxpod-fc-${P}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    PR=$(kubectl get pod "stress-${P}" -n "maxpod-fc-${P}" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null || echo "0")
    RS=0; for r in $PR; do RS=$((RS + r)); done
    TOTAL_RESTARTS=$((TOTAL_RESTARTS + RS))
    if [ "$PS" != "Running" ] || [ "$RS" -gt 0 ]; then
      ALL_OK="FAIL(pod-${P}:${PS}:${RS}r)"
      log "WARNING: Pod $P — status=$PS restarts=$RS"
    fi
  done

  # Metrics
  KT=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "N/A N/A N/A N/A N/A")
  NC=$(echo "$KT" | awk '{print $2}'); NCP=$(echo "$KT" | awk '{print $3}')
  NM=$(echo "$KT" | awk '{print $4}'); NMP=$(echo "$KT" | awk '{print $5}')

  SC=$(kubectl top pod -n "maxpod-fc-${N}" --containers --no-headers 2>/dev/null | awk '{gsub(/m/,"",$3); sum+=$3} END {printf "%dm", sum}' || echo "N/A")
  SM=$(kubectl top pod -n "maxpod-fc-${N}" --containers --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$4); sum+=$4} END {printf "%dMi", sum}' || echo "N/A")

  log "Pod $N: ok=$ALL_OK restarts=$TOTAL_RESTARTS cpu=$NC($NCP) mem=$NM($NMP) pod_cpu=$SC pod_mem=$SM"
  echo "${N},${DEPLOY_TIME},${READY_TIME},${SETTLE_TIME},Running,${TOTAL_RESTARTS},${NC},${NCP},${NM},${NMP},${ALL_OK},${SC},${SM}" >> "$RESULTS_CSV"

  if [ "$TOTAL_RESTARTS" -gt 0 ]; then
    STOP_REASON="Restarts after pod $N: total=$TOTAL_RESTARTS"
    log "STOP: $STOP_REASON"
    LAST_STABLE=$((N - 1))
    break
  fi

  LAST_STABLE=$N
  log "Pod $N stable."
done

if [ -z "$STOP_REASON" ]; then
  STOP_REASON="Reached max ($MAX_PODS)"
  LAST_STABLE=$MAX_PODS
fi

log ""
log "=== TEST COMPLETE ==="
log "Stop reason: $STOP_REASON"
log "Max stable pods: $LAST_STABLE"
log ""

log "=== SUMMARY TABLE ==="
column -t -s',' "$RESULTS_CSV" 2>/dev/null | tee -a "$LOG_FILE" || cat "$RESULTS_CSV" | tee -a "$LOG_FILE"

log ""
log "=== Node Allocated ==="
kubectl describe node "$NODE" 2>/dev/null | grep -A12 "Allocated resources" | tee -a "$LOG_FILE"

log ""
log "Cleaning up..."
cleanup
log "Done."
