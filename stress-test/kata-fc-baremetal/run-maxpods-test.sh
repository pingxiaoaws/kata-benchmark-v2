#!/usr/bin/env bash
# kata-fc Max Pod Density on m7g.metal - FINAL version
# Key fix: no exec>tee, no heredoc+background combo

RESULTS_DIR="/home/ec2-user/kata-benchmark-v2/results"
CSV="$RESULTS_DIR/v2-test-fc-maxpods.csv"
LOGFILE="$RESULTS_DIR/v2-test-fc-maxpods-stdout.log"

NS="bench-fc-maxpods"
NODE="ip-172-31-22-115.us-west-2.compute.internal"
RC="kata-fc"
IMG="busybox:1.36"
MEM="64Mi"; CPU="10m"
BATCH=10; MAX=250

log() {
  local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  echo "$msg"
  echo "$msg" >> "$LOGFILE"
}

count_status() {
  local n
  n=$(kubectl get pods -n "$NS" -l app=fc-maxpods --no-headers 2>/dev/null | grep -c "$1" 2>/dev/null) || n=0
  echo "$n"
}

snap() {
  local lbl="$1"
  local r p f
  r=$(count_status Running)
  p=$(count_status Pending)
  f=$(count_status Failed)
  echo "$lbl,$r,$p,$f" >> "$CSV"
  log "[$lbl] running=$r pending=$p failed=$f"
}

gen_pod_yaml() {
  local i=$1
  local name="fc-maxpods-$(printf '%04d' "$i")"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS
  labels: {app: fc-maxpods}
spec:
  runtimeClassName: $RC
  nodeSelector: {kubernetes.io/hostname: "$NODE"}
  terminationGracePeriodSeconds: 0
  containers:
  - name: s
    image: $IMG
    command: [sleep, "86400"]
    resources:
      requests: {memory: "$MEM", cpu: "$CPU"}
      limits: {memory: "$MEM", cpu: "$CPU"}
  restartPolicy: Never
---
EOF
}

: > "$LOGFILE"

log "=========================================="
log "kata-fc Max Pod Density Test"
log "m7g.metal: 64 vCPU, 256 GiB, aarch64"
log "FC overhead: cpu=250m mem=130Mi"
log "Pod request: mem=$MEM cpu=$CPU"
log "Effective/pod: mem=194Mi cpu=260m"
log "Theoretical max: CPU=63770/260=~245, EKS=250"
log "=========================================="

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

echo "target,running,pending,failed" > "$CSV"
snap "baseline"

hit_limit=""

for bstart in $(seq 1 "$BATCH" "$MAX"); do
  bend=$((bstart + BATCH - 1))
  [ "$bend" -gt "$MAX" ] && bend=$MAX

  log "--- Deploy $bstart..$bend ---"

  # Generate all pod YAML into one file and apply at once
  tmpfile=$(mktemp /tmp/fc-batch-XXXXXX.yaml)
  for i in $(seq "$bstart" "$bend"); do
    gen_pod_yaml "$i" >> "$tmpfile"
  done
  kubectl apply -f "$tmpfile" >/dev/null 2>&1
  rm -f "$tmpfile"

  # Wait up to 120s
  for attempt in $(seq 1 24); do
    sleep 5
    r=$(count_status Running)
    p=$(count_status Pending)

    if [ "$r" -ge "$bend" ]; then
      break
    fi

    # Check Unschedulable
    if [ "$p" -gt 0 ]; then
      first_pending=$(kubectl get pods -n "$NS" -l app=fc-maxpods --no-headers 2>/dev/null | grep Pending | head -1 | awk '{print $1}')
      if [ -n "$first_pending" ]; then
        reason=$(kubectl get pod -n "$NS" "$first_pending" -o jsonpath='{.status.conditions[?(@.reason=="Unschedulable")].message}' 2>/dev/null) || reason=""
        if [ -n "$reason" ]; then
          log "UNSCHEDULABLE: $reason"
          hit_limit="scheduling"
          break 2
        fi
      fi
    fi

    log "  wait $attempt: running=$r pending=$p"
  done

  r=$(count_status Running)
  if [ "$r" -lt "$bend" ] && [ -z "$hit_limit" ]; then
    f=$(count_status Failed)
    if [ "$f" -gt 3 ]; then
      log "TOO MANY FAILURES: $f"
      hit_limit="failures"
    else
      log "TIMEOUT at target=$bend, running=$r"
      hit_limit="timeout"
    fi
    snap "$bend"
    break
  fi

  snap "$bend"
  log "  $r pods running"
done

# Final
log ""
log "========== FINAL =========="
snap "final"

kubectl get pods -n "$NS" -l app=fc-maxpods --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn | while read line; do log "  $line"; done

final_running=$(count_status Running)

if [ -n "$hit_limit" ]; then
  log "Limit reason: $hit_limit"
  p=$(count_status Pending)
  if [ "$p" -gt 0 ]; then
    log "=== Pending Reasons ==="
    kubectl get pods -n "$NS" -l app=fc-maxpods --no-headers 2>/dev/null | grep Pending | head -3 | awk '{print $1}' | while read pp; do
      msg=$(kubectl get pod -n "$NS" "$pp" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null) || msg="unknown"
      log "  $pp: $msg"
    done
  fi
fi

log ""
log "=== Node Allocated ==="
kubectl describe node "$NODE" 2>/dev/null | grep -A12 "Allocated resources" | while read line; do log "  $line"; done

log ""
log "============================================"
log "MAX KATA-FC PODS ON m7g.metal: $final_running"
log "============================================"
log "CSV: $CSV  Log: $LOGFILE"
log "Cleanup: kubectl delete ns $NS"
