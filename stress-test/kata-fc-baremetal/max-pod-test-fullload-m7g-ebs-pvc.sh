#!/usr/bin/env bash
# max-pod-test-fullload-m7g-ebs-pvc.sh — Max pod density with Full-Load + EBS PVC per pod
# kata-fc on m7g.metal (64 vCPU, 256 GiB, Graviton3 bare metal)
#
# Each pod mounts a 1Gi EBS PVC to test EBS attachment limits.
# m7g.metal max EBS attachments = 31, minus root(1) + devmapper(1) = ~29 usable for PVC.
#
# Uses busybox (single-layer image) for kata-fc devmapper compatibility.

set -euo pipefail

NODE="${1:-ip-172-31-42-51.us-west-2.compute.internal}"
RUNTIME="kata-fc"
MAX_PODS=35   # above EBS limit to find the wall
SETTLE_SEC=60
READY_TIMEOUT=300
RESULTS_CSV="results-fullload-m7g-ebs-pvc.csv"
LOG_FILE="test-fullload-m7g-ebs-pvc.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

cd "$(dirname "$0")"
> "$LOG_FILE"

log "=== Max Pod Full-Load Test with EBS PVC: kata-fc on m7g.metal ==="
log "64 vCPU, 256 GiB, Graviton3, bare metal, aarch64"
log "Runtime: $RUNTIME, Overhead: cpu=250m mem=130Mi"
log "Pod: 4 containers (busybox) + 1Gi EBS PVC each"
log "Pod resources: 450m/2048Mi + overhead = 700m/2178Mi"

# Check node
log "Checking node..."
kubectl get node "$NODE" -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' --no-headers | tee -a "$LOG_FILE"
ALLOC_CPU=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')
ALLOC_MEM_KI=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//')
ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
log "Allocatable: ${ALLOC_CPU} CPU, ${ALLOC_MEM_MI} MiB memory"

# Baseline
log "Baseline top node: $(kubectl top node "$NODE" --no-headers 2>/dev/null || echo 'N/A')"

# CSV header
echo "pod_num,deploy_time,ready_time,settle_time,pod_status,total_restarts,node_cpu,node_cpu_pct,node_mem,node_mem_pct,all_pods_ok,stress_cpu,stress_mem,pvc_status,ebs_vols_attached" > "$RESULTS_CSV"

log "Starting incremental pod deployment..."

MAX_STABLE=0
STOP_REASON=""

for i in $(seq 1 "$MAX_PODS"); do
  NS="maxpod-fc-$i"
  POD="stress-$i"
  PVC="stress-pvc-$i"
  DEPLOY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
  
  log "--- Deploying pod $i ---"
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  runtimeClassName: $RUNTIME
  nodeSelector:
    benchmark-node: m7g-metal
  terminationGracePeriodSeconds: 5
  tolerations:
  - key: kata-dedicated
    operator: Equal
    value: "true"
    effect: NoSchedule
  volumes:
  - name: ebs-vol
    persistentVolumeClaim:
      claimName: $PVC
  containers:
  - name: gateway
    image: busybox:1.36
    command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/fill bs=1M count=900 2>/dev/null; dd if=/dev/zero of=/mnt/ebs/fill bs=1M count=100 2>/dev/null; while true; do :; done"]
    volumeMounts:
    - name: ebs-vol
      mountPath: /mnt/ebs
    resources:
      requests: {cpu: "150m", memory: "1Gi"}
      limits:   {cpu: "150m", memory: "1Gi"}
  - name: config-watcher
    image: busybox:1.36
    command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/fill bs=1M count=200 2>/dev/null; while true; do :; done"]
    resources:
      requests: {cpu: "100m", memory: "256Mi"}
      limits:   {cpu: "100m", memory: "256Mi"}
  - name: envoy
    image: busybox:1.36
    command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/fill bs=1M count=200 2>/dev/null; while true; do :; done"]
    resources:
      requests: {cpu: "100m", memory: "256Mi"}
      limits:   {cpu: "100m", memory: "256Mi"}
  - name: wazuh
    image: busybox:1.36
    command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/fill bs=1M count=450 2>/dev/null; while true; do :; done"]
    resources:
      requests: {cpu: "100m", memory: "512Mi"}
      limits:   {cpu: "100m", memory: "512Mi"}
  restartPolicy: Always
EOF

  # Wait for pod Ready
  log "Waiting for pod $POD to be Ready (max ${READY_TIMEOUT}s)..."
  READY=false
  for s in $(seq 1 "$READY_TIMEOUT"); do
    STATUS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    READY_COND=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$READY_COND" = "True" ]; then
      READY=true
      break
    fi
    if [ "$STATUS" = "Failed" ]; then break; fi
    sleep 1
  done
  
  READY_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
  
  if ! $READY; then
    log "Pod $i FAILED to become Ready (status: $STATUS)"
    STOP_REASON="Pod $i failed to become Ready (status: $STATUS)"
    
    # Still record the data point
    NODE_TOP=$(kubectl top node "$NODE" --no-headers 2>/dev/null | awk '{print $2","$3","$4","$5}' || echo "0m,0%,0Mi,0%")
    PVC_STATUS=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    EBS_COUNT=$(aws ec2 describe-volumes --region us-west-2 --filters "Name=attachment.instance-id,Values=i-00f56fa50fa7392c9" --query 'length(Volumes)' --output text 2>/dev/null || echo "?")
    echo "$i,$DEPLOY_TIME,$READY_TIME,FAILED,Failed,0,$NODE_TOP,FAIL,0m,0Mi,$PVC_STATUS,$EBS_COUNT" >> "$RESULTS_CSV"
    break
  fi
  
  log "Settling ${SETTLE_SEC}s..."
  sleep "$SETTLE_SEC"
  SETTLE_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
  
  # Collect metrics
  POD_STATUS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  RESTARTS=$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}{end}' 2>/dev/null | awk '{s+=$1}END{print s+0}')
  NODE_TOP=$(kubectl top node "$NODE" --no-headers 2>/dev/null | awk '{print $2","$3","$4","$5}' || echo "0m,0%,0Mi,0%")
  PVC_STATUS=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  EBS_COUNT=$(aws ec2 describe-volumes --region us-west-2 --filters "Name=attachment.instance-id,Values=i-00f56fa50fa7392c9" --query 'length(Volumes)' --output text 2>/dev/null || echo "?")
  
  # Check all pods across all namespaces
  ALL_OK="OK"
  for j in $(seq 1 "$i"); do
    P_STATUS=$(kubectl get pod "stress-$j" -n "maxpod-fc-$j" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    P_READY=$(kubectl get pod "stress-$j" -n "maxpod-fc-$j" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    P_RESTARTS=$(kubectl get pod "stress-$j" -n "maxpod-fc-$j" -o jsonpath='{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1}END{print s+0}')
    if [ "$P_READY" != "True" ] || [ "$P_RESTARTS" -gt 0 ] 2>/dev/null; then
      ALL_OK="FAIL(pod-$j:$P_STATUS:${P_RESTARTS}r)"
      break
    fi
  done
  
  # Pod-level CPU/mem from kubectl top
  POD_TOP=$(kubectl top pod "$POD" -n "$NS" --containers --no-headers 2>/dev/null | awk '{cpu+=$3; mem+=$4} END{printf "%dm,%dMi", cpu, mem}' || echo "0m,0Mi")
  STRESS_CPU=$(echo "$POD_TOP" | cut -d, -f1)
  STRESS_MEM=$(echo "$POD_TOP" | cut -d, -f2)
  
  echo "$i,$DEPLOY_TIME,$READY_TIME,$SETTLE_TIME,$POD_STATUS,$RESTARTS,$NODE_TOP,$ALL_OK,$STRESS_CPU,$STRESS_MEM,$PVC_STATUS,$EBS_COUNT" >> "$RESULTS_CSV"
  log "Pod $i: $POD_STATUS restarts=$RESTARTS $ALL_OK pvc=$PVC_STATUS ebs_vols=$EBS_COUNT node=($NODE_TOP)"
  
  if [ "$ALL_OK" != "OK" ]; then
    STOP_REASON="Health check failed: $ALL_OK"
    MAX_STABLE=$((i - 1))
    break
  fi
  
  MAX_STABLE=$i
done

if [ -z "$STOP_REASON" ]; then
  STOP_REASON="Reached MAX_PODS=$MAX_PODS"
fi

log ""
log "=== TEST COMPLETE ==="
log "Stop reason: $STOP_REASON"
log "Max stable pods: $MAX_STABLE"

log ""
log "=== Node Allocated ==="
kubectl describe node "$NODE" | grep -A 20 "Allocated resources:" | tee -a "$LOG_FILE"

log ""
log "Cleaning up..."
log "Cleaning up all maxpod-fc-* namespaces..."
kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep '^maxpod-fc-' | xargs -rn1 kubectl delete ns --force --grace-period=0 2>/dev/null
log "Cleanup done."
log "Done."
