#!/usr/bin/env bash
# efs-fio-benchmark-v2.sh — EFS I/O: gVisor vs runc on same Graviton node
set -uo pipefail

NODE="${1:-ip-172-31-9-46.us-west-2.compute.internal}"
EFS_SC="efs-sc"
RESULTS_CSV="results-efs-fio.csv"
LOG_FILE="test-efs-fio.log"
FIO_RUNTIME=60
IMAGE="ubuntu:22.04"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

log "=== EFS fio Benchmark v2 ==="

echo "runtime,test,rw,bs,bw_kib,bw_mib,iops,lat_avg_us,lat_p99_us" > "$RESULTS_CSV"

deploy_pod() {
  local NS=$1 RC=$2
  kubectl create ns "$NS" 2>/dev/null || true
  
  local RC_LINE=""
  [ "$RC" = "gvisor" ] && RC_LINE="runtimeClassName: gvisor"
  
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-fio
  namespace: ${NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${EFS_SC}
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: fio
  namespace: ${NS}
spec:
  ${RC_LINE}
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
      claimName: efs-fio
  containers:
  - name: main
    image: ${IMAGE}
    command: ["/bin/bash","-c","apt-get update -qq && apt-get install -y -qq fio jq >/dev/null 2>&1 && echo READY && sleep infinity"]
    resources:
      requests: { cpu: "2", memory: "4Gi" }
      limits:   { cpu: "4", memory: "4Gi" }
    volumeMounts:
    - name: efs-vol
      mountPath: /data
YAML

  log "Waiting PVC bind..."
  for i in $(seq 1 60); do
    [ "$(kubectl get pvc efs-fio -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] && break
    sleep 3
  done
  
  log "Waiting pod Ready (up to 300s)..."
  kubectl wait pod/fio -n "$NS" --for=condition=Ready --timeout=300s 2>&1 | tee -a "$LOG_FILE"
  
  # Wait for fio to be installed
  log "Waiting for fio install..."
  for i in $(seq 1 60); do
    if kubectl logs fio -n "$NS" 2>/dev/null | grep -q "READY"; then break; fi
    sleep 5
  done
  log "fio installed, ready to test."
}

run_fio() {
  local NS=$1 RUNTIME=$2 TEST=$3 RW=$4 BS=$5
  
  log "[$RUNTIME] $TEST: rw=$RW bs=$BS iodepth=32 numjobs=4 runtime=${FIO_RUNTIME}s"
  
  # Pre-create file for read tests
  if [[ "$RW" == "read" || "$RW" == "randread" ]]; then
    log "[$RUNTIME] Pre-creating 1G test file..."
    kubectl exec fio -n "$NS" -- bash -c "fio --name=pre --filename=/data/testfile --size=1G --rw=write --bs=1M --iodepth=1 --numjobs=1 --end_fsync=1 2>/dev/null"
    sleep 3
  fi
  
  local OUT
  OUT=$(kubectl exec fio -n "$NS" -- bash -c "fio --name=$TEST --filename=/data/testfile --size=1G --rw=$RW --bs=$BS --iodepth=32 --numjobs=4 --runtime=$FIO_RUNTIME --time_based --group_reporting --end_fsync=1 --output-format=json 2>&1" 2>&1) || true
  
  if ! echo "$OUT" | jq '.jobs[0]' >/dev/null 2>&1; then
    log "[$RUNTIME] $TEST: fio output parse failed, raw output:"
    echo "$OUT" | tail -20 | tee -a "$LOG_FILE"
    echo "${RUNTIME},${TEST},${RW},${BS},0,0,0,0,0" >> "$RESULTS_CSV"
    kubectl exec fio -n "$NS" -- rm -f /data/testfile 2>/dev/null || true
    sleep 3
    return
  fi
  
  local PREFIX="write"
  [[ "$RW" == "read" || "$RW" == "randread" ]] && PREFIX="read"
  
  local BW_KIB IOPS LAT_AVG LAT_P99
  BW_KIB=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.bw" 2>/dev/null || echo 0)
  IOPS=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.iops" 2>/dev/null || echo 0)
  LAT_AVG=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.lat_ns.mean" 2>/dev/null || echo 0)
  LAT_P99=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.clat_ns.percentile.\"99.000000\"" 2>/dev/null || echo 0)
  
  local BW_MIB LAT_AVG_US LAT_P99_US
  BW_MIB=$(echo "scale=2; $BW_KIB / 1024" | bc)
  LAT_AVG_US=$(echo "scale=1; $LAT_AVG / 1000" | bc)
  LAT_P99_US=$(echo "scale=1; $LAT_P99 / 1000" | bc)
  IOPS=$(printf "%.0f" "$IOPS")
  
  log "[$RUNTIME] $TEST: BW=${BW_MIB} MiB/s  IOPS=${IOPS}  lat_avg=${LAT_AVG_US}us  lat_p99=${LAT_P99_US}us"
  echo "${RUNTIME},${TEST},${RW},${BS},${BW_KIB},${BW_MIB},${IOPS},${LAT_AVG_US},${LAT_P99_US}" >> "$RESULTS_CSV"
  
  kubectl exec fio -n "$NS" -- rm -f /data/testfile 2>/dev/null || true
  sleep 3
}

cleanup_ns() {
  kubectl delete ns "$1" --force --grace-period=0 2>/dev/null || true
}

trap "cleanup_ns efs-fio-gvisor; cleanup_ns efs-fio-runc" EXIT

# --- gVisor ---
log "=== Phase 1: gVisor ==="
deploy_pod "efs-fio-gvisor" "gvisor"
run_fio "efs-fio-gvisor" "gvisor" "seq-write"  "write"     "1M"
run_fio "efs-fio-gvisor" "gvisor" "seq-read"   "read"      "1M"
run_fio "efs-fio-gvisor" "gvisor" "rand-write" "randwrite" "4k"
run_fio "efs-fio-gvisor" "gvisor" "rand-read"  "randread"  "4k"
cleanup_ns "efs-fio-gvisor"
sleep 10

# --- runc ---
log "=== Phase 2: runc ==="
deploy_pod "efs-fio-runc" "runc"
run_fio "efs-fio-runc" "runc" "seq-write"  "write"     "1M"
run_fio "efs-fio-runc" "runc" "seq-read"   "read"      "1M"
run_fio "efs-fio-runc" "runc" "rand-write" "randwrite" "4k"
run_fio "efs-fio-runc" "runc" "rand-read"  "randread"  "4k"

log "=== All done ==="
cat "$RESULTS_CSV" | tee -a "$LOG_FILE"
