#!/usr/bin/env bash
# s3files-fio-benchmark.sh — S3 Files I/O: gVisor vs runc
# 用法: ./s3files-fio-benchmark.sh [node]
set -uo pipefail

NODE="${1:-ip-172-31-9-46.us-west-2.compute.internal}"
S3FILES_SC="s3files-sc"
RESULTS_DIR="results"
RESULTS_CSV="$RESULTS_DIR/results-s3files-fio.csv"
LOG_FILE="$RESULTS_DIR/test-s3files-fio.log"
FIO_RUNTIME=60
IMAGE="ubuntu:22.04"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }

log "=== S3 Files fio Benchmark ==="
log "Node: $NODE"

echo "runtime,test,rw,bs,bw_kib,bw_mib,iops,lat_avg_us,lat_p99_us" > "$RESULTS_CSV"

# ─────────────────────────────────────────────────
# Deploy pod for a given runtime
# ─────────────────────────────────────────────────
deploy_pod() {
  local NS=$1 RC=$2
  kubectl create ns "$NS" 2>/dev/null || true

  local RC_LINE="" TOL_LINE=""
  if [ "$RC" = "gvisor" ]; then
    RC_LINE="runtimeClassName: gvisor"
    TOL_LINE=$(cat <<'EOF'
  tolerations:
  - key: gvisor
    operator: Equal
    value: "true"
    effect: NoSchedule
EOF
)
  fi

  local SEC_CTX=""
  if [ "$RC" = "gvisor-uid1000" ]; then
    RC_LINE="runtimeClassName: gvisor"
    TOL_LINE=$(cat <<'EOF'
  tolerations:
  - key: gvisor
    operator: Equal
    value: "true"
    effect: NoSchedule
EOF
)
    SEC_CTX=$(cat <<'EOF'
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
EOF
)
  fi

  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3files-fio
  namespace: ${NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${S3FILES_SC}
  resources:
    requests:
      storage: 100Gi
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
${TOL_LINE}
${SEC_CTX}
  volumes:
  - name: s3files-vol
    persistentVolumeClaim:
      claimName: s3files-fio
  containers:
  - name: main
    image: ${IMAGE}
    command: ["/bin/bash","-c","apt-get update -qq && apt-get install -y -qq fio jq >/dev/null 2>&1 && echo READY && sleep infinity"]
    resources:
      requests: { cpu: "2", memory: "4Gi" }
      limits:   { cpu: "4", memory: "4Gi" }
    volumeMounts:
    - name: s3files-vol
      mountPath: /data
YAML

  log "Waiting PVC bind..."
  for i in $(seq 1 60); do
    [ "$(kubectl get pvc s3files-fio -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] && break
    sleep 3
  done

  log "Waiting pod Ready (up to 300s)..."
  kubectl wait pod/fio -n "$NS" --for=condition=Ready --timeout=300s 2>&1 | tee -a "$LOG_FILE"

  # Wait for fio install
  log "Waiting for fio install..."
  for i in $(seq 1 60); do
    if kubectl logs fio -n "$NS" 2>/dev/null | grep -q "READY"; then break; fi
    sleep 5
  done
  log "fio installed, ready to test."
}

# ─────────────────────────────────────────────────
# Run a single fio test
# ─────────────────────────────────────────────────
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

  # Parse JSON output
  local BW_KIB IOPS LAT_AVG LAT_P99
  local RW_KEY="write"
  [[ "$RW" == "read" || "$RW" == "randread" ]] && RW_KEY="read"

  BW_KIB=$(echo "$OUT" | jq -r ".jobs[0].${RW_KEY}.bw // 0" 2>/dev/null || echo "0")
  IOPS=$(echo "$OUT" | jq -r ".jobs[0].${RW_KEY}.iops // 0" 2>/dev/null || echo "0")
  LAT_AVG=$(echo "$OUT" | jq -r ".jobs[0].${RW_KEY}.lat_ns.mean // 0" 2>/dev/null || echo "0")
  LAT_P99=$(echo "$OUT" | jq -r ".jobs[0].${RW_KEY}.clat_ns.percentile.\"99.000000\" // 0" 2>/dev/null || echo "0")

  # Convert ns → us
  LAT_AVG=$(echo "scale=2; $LAT_AVG / 1000" | bc 2>/dev/null || echo "0")
  LAT_P99=$(echo "scale=2; $LAT_P99 / 1000" | bc 2>/dev/null || echo "0")
  local BW_MIB
  BW_MIB=$(echo "scale=2; $BW_KIB / 1024" | bc 2>/dev/null || echo "0")

  log "[$RUNTIME] $TEST: BW=${BW_MIB} MiB/s, IOPS=${IOPS}, lat_avg=${LAT_AVG}us, lat_p99=${LAT_P99}us"
  echo "$RUNTIME,$TEST,$RW,$BS,$BW_KIB,$BW_MIB,$IOPS,$LAT_AVG,$LAT_P99" >> "$RESULTS_CSV"
}

# ─────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────
cleanup_ns() {
  local NS=$1
  log "Cleaning up namespace $NS..."
  kubectl delete pod fio -n "$NS" --grace-period=0 --force 2>/dev/null || true
  kubectl delete pvc s3files-fio -n "$NS" 2>/dev/null || true
  sleep 5
}

# ─────────────────────────────────────────────────
# Phase 1: 可用性验证
# ─────────────────────────────────────────────────
verify_access() {
  local NS=$1 RUNTIME=$2

  log "=== [$RUNTIME] Verifying S3 Files access ==="

  # Basic write test
  log "[$RUNTIME] Testing write..."
  local WRITE_OK
  WRITE_OK=$(kubectl exec fio -n "$NS" -- bash -c "echo 'hello s3files' > /data/test-write.txt && echo OK || echo FAIL" 2>&1)
  log "[$RUNTIME] Write: $WRITE_OK"

  # Basic read test
  log "[$RUNTIME] Testing read..."
  local READ_OK
  READ_OK=$(kubectl exec fio -n "$NS" -- bash -c "cat /data/test-write.txt 2>&1 || echo FAIL")
  log "[$RUNTIME] Read: $READ_OK"

  # List test
  log "[$RUNTIME] Testing ls..."
  local LS_OK
  LS_OK=$(kubectl exec fio -n "$NS" -- bash -c "ls -la /data/ 2>&1 | head -10")
  log "[$RUNTIME] ls: $LS_OK"

  # Mount info
  log "[$RUNTIME] Mount info..."
  local MOUNT_INFO
  MOUNT_INFO=$(kubectl exec fio -n "$NS" -- bash -c "mount | grep /data || cat /proc/mounts | grep /data" 2>&1)
  log "[$RUNTIME] Mount: $MOUNT_INFO"

  # Permissions
  log "[$RUNTIME] ID and permissions..."
  local ID_INFO
  ID_INFO=$(kubectl exec fio -n "$NS" -- bash -c "id; stat /data/" 2>&1)
  log "[$RUNTIME] ID: $ID_INFO"
}

# ─────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────

# Test matrix
BLOCK_SIZES=("4k" "128k" "1M")
RW_MODES=("read" "write" "randread" "randwrite")

# --- runc baseline ---
NS_RUNC="s3files-runc"
log "===== Phase 1: runc baseline ====="
deploy_pod "$NS_RUNC" "runc"
verify_access "$NS_RUNC" "runc"

log "===== Phase 2: runc fio benchmark ====="
for BS in "${BLOCK_SIZES[@]}"; do
  for RW in "${RW_MODES[@]}"; do
    run_fio "$NS_RUNC" "runc" "runc-${RW}-${BS}" "$RW" "$BS"
    sleep 2
  done
done
cleanup_ns "$NS_RUNC"

# --- gvisor (root) ---
NS_GVISOR="s3files-gvisor"
log "===== Phase 3: gvisor (root) ====="
deploy_pod "$NS_GVISOR" "gvisor"
verify_access "$NS_GVISOR" "gvisor"

# If write works, run fio; otherwise skip
GVISOR_WRITE=$(kubectl exec fio -n "$NS_GVISOR" -- bash -c "echo test > /data/gvisor-test.txt && echo OK || echo FAIL" 2>&1)
if echo "$GVISOR_WRITE" | grep -q "OK"; then
  log "gvisor (root) write OK — running fio..."
  for BS in "${BLOCK_SIZES[@]}"; do
    for RW in "${RW_MODES[@]}"; do
      run_fio "$NS_GVISOR" "gvisor" "gvisor-${RW}-${BS}" "$RW" "$BS"
      sleep 2
    done
  done
else
  log "⚠️  gvisor (root) write FAILED — skipping fio (same issue as EFS NFS4)"
  log "    Output: $GVISOR_WRITE"
fi
cleanup_ns "$NS_GVISOR"

# --- gvisor uid=1000 ---
NS_GV1000="s3files-gvisor-uid1000"
log "===== Phase 4: gvisor uid=1000 ====="
deploy_pod "$NS_GV1000" "gvisor-uid1000"
verify_access "$NS_GV1000" "gvisor-uid1000"

GVISOR1000_WRITE=$(kubectl exec fio -n "$NS_GV1000" -- bash -c "echo test > /data/gv1000-test.txt && echo OK || echo FAIL" 2>&1)
if echo "$GVISOR1000_WRITE" | grep -q "OK"; then
  log "gvisor uid=1000 write OK — running fio..."
  for BS in "${BLOCK_SIZES[@]}"; do
    for RW in "${RW_MODES[@]}"; do
      run_fio "$NS_GV1000" "gvisor-uid1000" "gvisor1000-${RW}-${BS}" "$RW" "$BS"
      sleep 2
    done
  done
else
  log "⚠️  gvisor uid=1000 write FAILED"
  log "    Output: $GVISOR1000_WRITE"
fi
cleanup_ns "$NS_GV1000"

# ─────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────
log ""
log "=== Benchmark Complete ==="
log "Results: $RESULTS_CSV"
log "Log:     $LOG_FILE"
log ""
log "--- CSV Preview ---"
cat "$RESULTS_CSV" | tee -a "$LOG_FILE"
