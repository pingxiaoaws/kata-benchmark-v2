#!/usr/bin/env bash
set -euo pipefail

# === Test 5b: Memory Oversell Stability Test ===
# Find kata-qemu memory oversell OOM tipping point using pause containers.
# Compare VM overhead vs runc to demonstrate why memory oversell is dangerous with Kata.

RESULTS_DIR="/home/ec2-user/benchmark/results"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/v2-test5b-memory-oversell.csv"
SUMMARY="$RESULTS_DIR/v2-test5b-summary.md"
LOGFILE="$RESULTS_DIR/v2-test5b-stdout.log"

NS="bench5b"
TARGET_NODE="ip-172-31-18-5.us-west-2.compute.internal"
PAUSE_IMAGE="registry.k8s.io/pause:3.10"
HOSTPOD_NAME="bench5b-hostpod"

# Tee all output to log
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------- helpers ----------

setup_ns() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
}

cleanup_ns() {
  log "Cleaning up namespace $NS..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
  # Wait for actual deletion
  for i in $(seq 1 60); do
    if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  log "Namespace $NS cleaned."
}

deploy_hostpod() {
  log "Deploying host-access privileged pod..."
  kubectl apply -n "$NS" -f - <<'HOSTEOF'
apiVersion: v1
kind: Pod
metadata:
  name: bench5b-hostpod
  labels:
    app: bench5b-hostpod
spec:
  hostPID: true
  nodeSelector:
    kubernetes.io/hostname: ip-172-31-18-5.us-west-2.compute.internal
  tolerations:
  - key: kata-oversell
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  - name: nsenter
    image: busybox:1.36
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
  restartPolicy: Never
HOSTEOF
  kubectl wait -n "$NS" pod/"$HOSTPOD_NAME" --for=condition=Ready --timeout=60s
  log "Hostpod ready."
}

get_mem_available_mib() {
  local raw
  raw=$(kubectl exec -n "$NS" "$HOSTPOD_NAME" -- nsenter -t 1 -m cat /proc/meminfo 2>/dev/null | grep '^MemAvailable:' | awk '{print $2}')
  if [[ -z "$raw" ]]; then
    echo "N/A"
  else
    echo $(( raw / 1024 ))
  fi
}

get_oom_events() {
  # Only count actual OOM kills, not regular pod terminations
  local count
  count=$(kubectl get events -n "$NS" --field-selector reason=OOMKilling --no-headers 2>/dev/null | wc -l)
  # Also check dmesg-style OOM via node events (broader scope)
  local count2
  count2=$(kubectl get events --all-namespaces --field-selector reason=OOMKilling --no-headers 2>/dev/null | wc -l)
  # Use the max of the two
  if [[ "$count2" -gt "$count" ]]; then
    echo "$count2"
  else
    echo "$count"
  fi
}

# Baseline OOM count to compute deltas
OOM_BASELINE=0
set_oom_baseline() {
  OOM_BASELINE=$(get_oom_events)
  log "OOM baseline set to $OOM_BASELINE"
}

get_oom_delta() {
  local current
  current=$(get_oom_events)
  echo $(( current - OOM_BASELINE ))
}

gen_deployment_yaml() {
  local name="$1" runtime="$2" replicas="$3" mem_req="${4:-128Mi}" mem_lim="${5:-256Mi}"

  local runtime_line=""
  if [[ "$runtime" != "runc" ]]; then
    runtime_line="      runtimeClassName: $runtime"
  fi

  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: $NS
spec:
  replicas: $replicas
  selector:
    matchLabels:
      app: $name
  template:
    metadata:
      labels:
        app: $name
    spec:
$runtime_line
      nodeSelector:
        kubernetes.io/hostname: $TARGET_NODE
      tolerations:
      - key: kata-oversell
        operator: Equal
        value: "true"
        effect: NoSchedule
      containers:
      - name: pause
        image: $PAUSE_IMAGE
        resources:
          requests:
            memory: "$mem_req"
            cpu: "50m"
          limits:
            memory: "$mem_lim"
            cpu: "100m"
EOF
}

collect_pod_status() {
  local deploy_name="$1" target="$2"
  local running=0 pending=0 failed=0

  local statuses
  statuses=$(kubectl get pods -n "$NS" -l "app=$deploy_name" --no-headers 2>/dev/null || true)

  running=$(echo "$statuses" | grep -c "Running" || true)
  pending=$(echo "$statuses" | grep -c "Pending" || true)
  failed=$(echo "$statuses" | grep -cE "Failed|Error|CrashLoopBackOff|OOMKilled" || true)

  echo "$running $pending $failed"
}

record_csv() {
  local test="$1" phase="$2" runtime="$3" num_pods="$4" target_pods="$5"
  local running="$6" pending="$7" failed="$8" mem_avail="$9" oom="${10}"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "$test,$phase,$runtime,$num_pods,$target_pods,$running,$pending,$failed,$mem_avail,$oom,$ts" >> "$CSV"
}

# Global variable for returning results from scale_and_measure
MEASURE_RESULT=""

# Scale deployment and measure
scale_and_measure() {
  local deploy_name="$1" runtime="$2" target="$3" phase="$4" test_label="$5"

  log "Scaling $deploy_name to $target replicas (runtime=$runtime)..."
  kubectl scale deployment/"$deploy_name" -n "$NS" --replicas="$target" >/dev/null 2>&1

  # Wait for pods to be ready (timeout ok)
  log "Waiting up to 120s for pods to reach Ready state..."
  kubectl wait -n "$NS" --for=condition=Ready pod -l "app=$deploy_name" --timeout=120s 2>/dev/null || true

  # Extra settle time
  sleep 10

  # Collect status
  local status_line
  status_line=$(collect_pod_status "$deploy_name" "$target")
  local running pending failed
  running=$(echo "$status_line" | awk '{print $1}')
  pending=$(echo "$status_line" | awk '{print $2}')
  failed=$(echo "$status_line" | awk '{print $3}')

  # Memory
  local mem_avail
  mem_avail=$(get_mem_available_mib)

  # OOM events (delta from baseline)
  local oom
  oom=$(get_oom_delta)

  log "  target=$target running=$running pending=$pending failed=$failed MemAvailable=${mem_avail}MiB OOM=$oom"
  record_csv "$test_label" "$phase" "$runtime" "$target" "$target" "$running" "$pending" "$failed" "$mem_avail" "$oom"

  # Return via global variable instead of stdout (avoids tee interference)
  MEASURE_RESULT="$mem_avail|$running|$pending|$failed|$oom"
}

# ---------- main ----------

main() {
  log "=== Test 5b: Memory Oversell Stability Test ==="
  log "Target node: $TARGET_NODE (r8i.2xlarge, 8 vCPU, 64GB RAM)"
  log "Allocatable memory: ~60Gi"

  # Init CSV
  echo "test,phase,runtime,num_pods,target_pods,running_pods,pending_pods,failed_pods,mem_available_MiB,oom_events,timestamp" > "$CSV"

  # ========================================
  # Phase 1: Baseline comparison
  # ========================================
  log ""
  log "========== PHASE 1: Baseline Comparison (runc vs kata-qemu, 10 pods) =========="

  # --- runc baseline ---
  cleanup_ns
  setup_ns
  deploy_hostpod

  log "--- Phase 1a: runc baseline (10 pods) ---"
  local mem_before
  mem_before=$(get_mem_available_mib)
  log "MemAvailable before deployment: ${mem_before}MiB"
  record_csv "5b" "1-pre" "none" "0" "0" "0" "0" "0" "$mem_before" "0"

  gen_deployment_yaml "bench5b-runc" "runc" 10 | kubectl apply -f - >/dev/null 2>&1
  scale_and_measure "bench5b-runc" "runc" 10 "1-runc" "5b"
  local runc_mem
  runc_mem=$(echo "$MEASURE_RESULT" | cut -d'|' -f1)

  # --- kata-qemu baseline ---
  log "--- Phase 1b: kata-qemu baseline (10 pods) ---"
  kubectl delete deployment bench5b-runc -n "$NS" --ignore-not-found >/dev/null 2>&1
  # Wait for pods to terminate
  sleep 30
  set_oom_baseline
  local mem_after_cleanup
  mem_after_cleanup=$(get_mem_available_mib)
  log "MemAvailable after runc cleanup: ${mem_after_cleanup}MiB"

  gen_deployment_yaml "bench5b-kata" "kata-qemu" 10 | kubectl apply -f - >/dev/null 2>&1
  scale_and_measure "bench5b-kata" "kata-qemu" 10 "1-kata" "5b"
  local kata_mem
  kata_mem=$(echo "$MEASURE_RESULT" | cut -d'|' -f1)

  if [[ "$runc_mem" != "N/A" && "$kata_mem" != "N/A" ]]; then
    local overhead=$(( runc_mem - kata_mem ))
    local per_pod_overhead=$(( overhead / 10 ))
    log "==> VM overhead for 10 pods: ${overhead}MiB total, ~${per_pod_overhead}MiB per pod"
  fi

  # Clean up phase 1
  kubectl delete deployment bench5b-kata -n "$NS" --ignore-not-found >/dev/null 2>&1
  sleep 30

  # ========================================
  # Phase 2: Progressive load — find OOM tipping point
  # ========================================
  log ""
  log "========== PHASE 2: Progressive Load (kata-qemu, finding OOM tipping point) =========="

  # Reset OOM baseline so we only count new events from this phase
  set_oom_baseline

  local pod_steps=(10 20 30 40 50 60 80 100 120 150 200)
  local oom_tipping_point=0
  local max_safe_pods=0
  local stopped_early=false

  gen_deployment_yaml "bench5b-kata-load" "kata-qemu" 0 | kubectl apply -f - >/dev/null 2>&1

  for target in "${pod_steps[@]}"; do
    log ""
    log "--- Phase 2: Scaling to $target kata-qemu pods ---"

    scale_and_measure "bench5b-kata-load" "kata-qemu" "$target" "2-kata-$target" "5b"
    local mem running pending failed oom
    mem=$(echo "$MEASURE_RESULT" | cut -d'|' -f1)
    running=$(echo "$MEASURE_RESULT" | cut -d'|' -f2)
    pending=$(echo "$MEASURE_RESULT" | cut -d'|' -f3)
    failed=$(echo "$MEASURE_RESULT" | cut -d'|' -f4)
    oom=$(echo "$MEASURE_RESULT" | cut -d'|' -f5)

    # Track max safe pods (allow minor variance: running >= 90% of target, no OOM)
    local threshold=$(( target * 90 / 100 ))
    if [[ "$threshold" -lt 1 ]]; then threshold=1; fi
    if [[ "$mem" != "N/A" && "$running" -ge "$threshold" && "$oom" -eq 0 ]]; then
      max_safe_pods=$target
    fi

    # Detect OOM tipping point
    if [[ "$oom" -gt 0 && "$oom_tipping_point" -eq 0 ]]; then
      oom_tipping_point=$target
      log "!!! OOM TIPPING POINT detected at $target pods !!!"
    fi

    # Check pending (scheduler can't place)
    if [[ "$pending" -gt 0 ]]; then
      log "WARNING: $pending pods pending (scheduler pressure)"
    fi

    # Safety: stop if MemAvailable < 2Gi
    if [[ "$mem" != "N/A" && "$mem" -lt 2048 ]]; then
      log "!!! MemAvailable < 2GiB (${mem}MiB) — stopping to protect node !!!"
      stopped_early=true
      break
    fi
  done

  # Record the tipping point
  local kata_critical_pods=$oom_tipping_point
  if [[ "$kata_critical_pods" -eq 0 ]]; then
    # No OOM found — use last successful step
    kata_critical_pods=${pod_steps[-1]}
  fi

  # Clean up phase 2
  log "Cleaning up phase 2..."
  kubectl delete deployment bench5b-kata-load -n "$NS" --ignore-not-found >/dev/null 2>&1
  sleep 60
  log "Phase 2 cleanup done."

  # ========================================
  # Phase 3: runc comparison at critical pod count
  # ========================================
  log ""
  log "========== PHASE 3: runc Comparison at $max_safe_pods pods (kata max safe) =========="

  if [[ "$max_safe_pods" -gt 0 ]]; then
    local comparison_count=$max_safe_pods
    # If tipping point found, use that count for comparison
    if [[ "$oom_tipping_point" -gt 0 ]]; then
      comparison_count=$oom_tipping_point
    fi

    log "Deploying $comparison_count runc pods for comparison..."
    gen_deployment_yaml "bench5b-runc-compare" "runc" 0 | kubectl apply -f - >/dev/null 2>&1

    scale_and_measure "bench5b-runc-compare" "runc" "$comparison_count" "3-runc-$comparison_count" "5b"
    local runc_compare_mem runc_running runc_oom
    runc_compare_mem=$(echo "$MEASURE_RESULT" | cut -d'|' -f1)
    runc_running=$(echo "$MEASURE_RESULT" | cut -d'|' -f2)
    runc_oom=$(echo "$MEASURE_RESULT" | cut -d'|' -f5)

    log "runc at $comparison_count pods: MemAvailable=${runc_compare_mem}MiB running=$runc_running OOM=$runc_oom"

    # Also try kata's max step if different
    if [[ "$comparison_count" != "$max_safe_pods" ]]; then
      kubectl scale deployment/bench5b-runc-compare -n "$NS" --replicas=0 >/dev/null 2>&1
      sleep 15
      scale_and_measure "bench5b-runc-compare" "runc" "$max_safe_pods" "3-runc-$max_safe_pods" "5b"
    fi

    kubectl delete deployment bench5b-runc-compare -n "$NS" --ignore-not-found >/dev/null 2>&1
  else
    log "Skipping phase 3 — no safe pod count established."
  fi

  # ========================================
  # Generate Summary
  # ========================================
  log ""
  log "========== Generating Summary =========="

  {
    echo "# Test 5b: Memory Oversell Stability Test"
    echo ""
    echo "**Date:** $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "**Node:** $TARGET_NODE (r8i.2xlarge, 8 vCPU, 64GB RAM)"
    echo "**Allocatable memory:** ~60GiB"
    echo "**Pod spec:** pause container, request=128Mi, limit=256Mi, cpu req=50m/lim=100m"
    echo ""
    echo "## Phase 1: Baseline (10 pods)"
    echo ""
    echo "| Metric | runc | kata-qemu | Overhead |"
    echo "|--------|------|-----------|----------|"
    if [[ "$runc_mem" != "N/A" && "$kata_mem" != "N/A" ]]; then
      echo "| MemAvailable (MiB) | $runc_mem | $kata_mem | $((runc_mem - kata_mem)) MiB total (~$((( runc_mem - kata_mem ) / 10)) MiB/pod) |"
    else
      echo "| MemAvailable (MiB) | $runc_mem | $kata_mem | N/A |"
    fi
    echo ""
    echo "## Phase 2: Progressive Load (kata-qemu)"
    echo ""
    echo "| Pods | Running | Pending | Failed | MemAvailable (MiB) | OOM Events |"
    echo "|------|---------|---------|--------|-------------------|------------|"
    # Parse CSV for phase 2 rows
    grep ',2-kata-' "$CSV" | while IFS=',' read -r test phase runtime num target running pending failed mem oom ts; do
      echo "| $target | $running | $pending | $failed | $mem | $oom |"
    done
    echo ""
    if [[ "$oom_tipping_point" -gt 0 ]]; then
      echo "**OOM Tipping Point:** $oom_tipping_point pods"
    else
      echo "**OOM Tipping Point:** Not reached (tested up to ${pod_steps[-1]} pods)"
    fi
    echo "**Max Safe Pod Count:** $max_safe_pods"
    if [[ "$stopped_early" == "true" ]]; then
      echo "**Note:** Test stopped early due to MemAvailable < 2GiB"
    fi
    echo ""
    echo "## Phase 3: runc Comparison"
    echo ""
    if [[ "$max_safe_pods" -gt 0 ]]; then
      echo "runc was tested at the kata-qemu tipping point ($kata_critical_pods pods) to demonstrate"
      echo "that the same pod count does not cause OOM without VM overhead."
      echo ""
      grep ',3-runc-' "$CSV" | while IFS=',' read -r test phase runtime num target running pending failed mem oom ts; do
        echo "- runc $target pods: MemAvailable=${mem}MiB, OOM=$oom"
      done
    else
      echo "Phase 3 skipped — no safe baseline established."
    fi
    echo ""
    echo "## Key Findings"
    echo ""
    echo "- Each kata-qemu VM has a per-pod memory overhead from the QEMU process + guest kernel"
    echo "- Memory is incompressible — unlike CPU, overselling memory leads to OOM kills"
    echo "- runc containers share the host kernel and have negligible per-pod memory overhead"
    echo ""
    echo "## CSV Data"
    echo ""
    echo "Full results: \`$CSV\`"
  } > "$SUMMARY"

  log "Summary written to $SUMMARY"
  log "CSV written to $CSV"

  # Cleanup
  cleanup_ns

  log "=== Test 5b Complete ==="
}

main "$@"
