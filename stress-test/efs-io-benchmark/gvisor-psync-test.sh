#!/usr/bin/env bash
set -uo pipefail
NODE="ip-172-31-9-46.us-west-2.compute.internal"
NS="efs-fio-gvisor2"
LOG="test-gvisor-psync.log"
CSV="results-efs-fio.csv"  # append to existing

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG"; }

kubectl create ns "$NS" 2>/dev/null || true
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-fio
  namespace: ${NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
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
      claimName: efs-fio
  containers:
  - name: main
    image: ubuntu:22.04
    command: ["/bin/bash","-c","apt-get update -qq && apt-get install -y -qq fio jq bc >/dev/null 2>&1 && echo READY && sleep infinity"]
    resources:
      requests: { cpu: "2", memory: "4Gi" }
      limits:   { cpu: "4", memory: "4Gi" }
    volumeMounts:
    - name: efs-vol
      mountPath: /data
YAML

log "Waiting PVC..."
for i in $(seq 1 60); do
  [ "$(kubectl get pvc efs-fio -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] && break; sleep 3
done

log "Waiting pod Ready..."
kubectl wait pod/fio -n "$NS" --for=condition=Ready --timeout=300s 2>&1 | tee -a "$LOG"

log "Waiting for fio install..."
for i in $(seq 1 60); do
  kubectl logs fio -n "$NS" 2>/dev/null | grep -q "READY" && break; sleep 5
done
log "fio ready."

run_fio() {
  local TEST=$1 RW=$2 BS=$3
  log "[gvisor-psync] $TEST: rw=$RW bs=$BS ioengine=psync iodepth=1 numjobs=4 runtime=60s"
  
  if [[ "$RW" == "read" || "$RW" == "randread" ]]; then
    log "[gvisor-psync] Pre-creating test file..."
    kubectl exec fio -n "$NS" -- bash -c "fio --name=pre --filename=/data/testfile --size=1G --rw=write --bs=1M --ioengine=psync --iodepth=1 --numjobs=1 --end_fsync=1 --output-format=json 2>&1" >/dev/null 2>&1 || true
    sleep 3
  fi
  
  local OUT
  OUT=$(kubectl exec fio -n "$NS" -- bash -c "fio --name=$TEST --filename=/data/testfile --size=1G --rw=$RW --bs=$BS --ioengine=psync --iodepth=1 --numjobs=4 --runtime=60 --time_based --group_reporting --end_fsync=1 --output-format=json 2>&1" 2>&1) || true
  
  local PREFIX="write"
  [[ "$RW" == "read" || "$RW" == "randread" ]] && PREFIX="read"
  
  if ! echo "$OUT" | jq ".jobs[0].${PREFIX}" >/dev/null 2>&1; then
    log "[gvisor-psync] $TEST FAILED, raw tail:"
    echo "$OUT" | tail -10 | tee -a "$LOG"
    echo "gvisor-psync,${TEST},${RW},${BS},0,0,0,0,0" >> "$CSV"
    return
  fi
  
  local BW_KIB=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.bw")
  local IOPS=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.iops")
  local LAT_AVG=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.lat_ns.mean")
  local LAT_P99=$(echo "$OUT" | jq ".jobs[0].${PREFIX}.clat_ns.percentile.\"99.000000\" // 0")
  
  local BW_MIB=$(echo "scale=2; $BW_KIB / 1024" | bc)
  local LAT_AVG_US=$(echo "scale=1; $LAT_AVG / 1000" | bc)
  local LAT_P99_US=$(echo "scale=1; $LAT_P99 / 1000" | bc)
  IOPS=$(printf "%.0f" "$IOPS")
  
  log "[gvisor-psync] $TEST: BW=${BW_MIB} MiB/s  IOPS=${IOPS}  lat_avg=${LAT_AVG_US}us  lat_p99=${LAT_P99_US}us"
  echo "gvisor-psync,${TEST},${RW},${BS},${BW_KIB},${BW_MIB},${IOPS},${LAT_AVG_US},${LAT_P99_US}" >> "$CSV"
  
  kubectl exec fio -n "$NS" -- rm -f /data/testfile 2>/dev/null || true
  sleep 3
}

run_fio "seq-write"  "write"     "1M"
run_fio "seq-read"   "read"      "1M"
run_fio "rand-write" "randwrite" "4k"
run_fio "rand-read"  "randread"  "4k"

log "=== gVisor psync tests done ==="
kubectl delete ns "$NS" --force --grace-period=0 2>/dev/null || true
