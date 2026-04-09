#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test 9: kata-clh Memory Footprint Profiling
# Same 5 subtests as Test 7 (kata-qemu) for VMM comparison
# ============================================================

NODE="ip-172-31-19-254.us-west-2.compute.internal"
NS="bench9"
RESULTS="/home/ec2-user/kata-benchmark-v2/results"
PAUSE_IMAGE="registry.k8s.io/pause:3.10"
TAINT_KEY="kata-benchmark"
TAINT_VAL="true"
ROUNDS=3
LOGFILE="${RESULTS}/v2-test9-stdout.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Helper: create a privileged nsenter pod on the target node ──
deploy_hostpod() {
  local name="$1"
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  nodeName: ${NODE}
  hostPID: true
  hostNetwork: true
  tolerations:
  - key: "${TAINT_KEY}"
    value: "${TAINT_VAL}"
    effect: NoSchedule
  containers:
  - name: nsenter
    image: alpine:3.20
    command: ["sleep", "7200"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: hostroot
      mountPath: /host
  volumes:
  - name: hostroot
    hostPath:
      path: /
  terminationGracePeriodSeconds: 0
EOF
  kubectl wait -n ${NS} pod/${name} --for=condition=Ready --timeout=120s >/dev/null 2>&1
}

# ── Helper: run a command on host via nsenter pod ──
hostexec() {
  local podname="$1"; shift
  kubectl exec -n ${NS} ${podname} -- nsenter -t 1 -m -u -i -n -p -- "$@"
}

# ── Helper: get MemAvailable from host (in MiB) ──
get_mem_available() {
  hostexec hostpod sh -c "awk '/MemAvailable/ {printf \"%.0f\", \$2/1024}' /proc/meminfo"
}

# ── Helper: generate pause pod YAML ──
gen_pause_pod() {
  local name="$1" runtime="$2" ns="$3" mem_req="${4:-64Mi}" mem_lim="${5:-128Mi}"
  local rc_line=""
  [[ "$runtime" != "runc" ]] && rc_line="  runtimeClassName: ${runtime}"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: bench9
    runtime: ${runtime}
spec:
${rc_line}
  nodeName: ${NODE}
  tolerations:
  - key: "${TAINT_KEY}"
    value: "${TAINT_VAL}"
    effect: NoSchedule
  containers:
  - name: pause
    image: ${PAUSE_IMAGE}
    resources:
      requests:
        memory: "${mem_req}"
        cpu: "50m"
      limits:
        memory: "${mem_lim}"
        cpu: "100m"
  terminationGracePeriodSeconds: 0
EOF
}

# ── Helper: generate stress pod YAML ──
gen_stress_pod() {
  local name="$1" runtime="$2" ns="$3" stress_mb="$4"
  local rc_line="" mem_lim="2Gi"
  [[ "$runtime" != "runc" ]] && rc_line="  runtimeClassName: ${runtime}"

  if [[ "$stress_mb" == "0" ]]; then
    gen_pause_pod "$name" "$runtime" "$ns" "64Mi" "2Gi"
    return
  fi

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: bench9-stress
    runtime: ${runtime}
spec:
${rc_line}
  nodeName: ${NODE}
  tolerations:
  - key: "${TAINT_KEY}"
    value: "${TAINT_VAL}"
    effect: NoSchedule
  containers:
  - name: stress
    image: alexeiled/stress-ng:latest
    args: ["--vm", "1", "--vm-bytes", "${stress_mb}m", "--vm-hang", "300", "--timeout", "300s"]
    resources:
      requests:
        memory: "${mem_lim}"
        cpu: "100m"
      limits:
        memory: "${mem_lim}"
        cpu: "500m"
  terminationGracePeriodSeconds: 0
EOF
}

wait_pod_ready() {
  local name="$1" ns="$2" timeout="${3:-120s}"
  kubectl wait -n ${ns} pod/${name} --for=condition=Ready --timeout=${timeout} >/dev/null 2>&1
}

delete_test_pods() {
  kubectl get pods -n ${NS} --no-headers -o name 2>/dev/null | grep -v hostpod | while read p; do
    kubectl delete -n ${NS} "$p" --force --grace-period=0 2>/dev/null || true
  done
  sleep 5
}

get_cgroup_mem() {
  local pod_uid="$1"
  local puid=$(echo "$pod_uid" | tr '-' '_')
  for qos in burstable besteffort guaranteed; do
    local path="/sys/fs/cgroup/kubepods.slice/kubepods-${qos}.slice/kubepods-${qos}-pod${puid}.slice/memory.current"
    local val=$(hostexec hostpod sh -c "cat ${path} 2>/dev/null || echo ''" 2>/dev/null || echo "")
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      echo "$val"
      return
    fi
  done
  local path="/sys/fs/cgroup/kubepods.slice/kubepods-pod${puid}.slice/memory.current"
  hostexec hostpod sh -c "cat ${path} 2>/dev/null || echo ''" 2>/dev/null || echo ""
}

cleanup_ns() {
  kubectl delete namespace ${NS} --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  sleep 3
}

settle() { log "Settling ${1}s..."; sleep "$1"; }

# ============================================================
# MAIN - tee all output
# ============================================================
main() {

log "=== Test 9: kata-clh Memory Footprint Profiling ==="
log "Target node: ${NODE}"
log "Namespace: ${NS}"

# Create namespace
cleanup_ns
kubectl create namespace ${NS} >/dev/null 2>&1

# Deploy host access pod
log "Deploying host access pod..."
deploy_hostpod "hostpod"

MEM_TOTAL=$(hostexec hostpod sh -c "awk '/MemTotal/ {printf \"%.0f\", \$2/1024}' /proc/meminfo")
log "Node total memory: ${MEM_TOTAL} MiB"

# ============================================================
# Test 9A: Single Pod Idle Memory Delta
# ============================================================
log ""
log "=== Test 9A: Single Pod Idle Memory Delta ==="

CSV_9A="${RESULTS}/v2-test9a-idle-memory-delta.csv"
echo "test,runtime,round,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp" > "$CSV_9A"

for runtime in runc kata-clh; do
  for round in $(seq 1 $ROUNDS); do
    log "9A: ${runtime} round ${round} - measuring baseline..."
    settle 10

    baseline=$(get_mem_available)
    log "  Baseline MemAvailable: ${baseline} MiB"

    podname="t9a-${runtime}-r${round}"
    gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
    wait_pod_ready "$podname" "$NS"

    settle 10

    after=$(get_mem_available)
    delta=$((baseline - after))
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Delta: ${delta} MiB"

    echo "9A,${runtime},${round},${baseline},${after},${delta},${ts}" >> "$CSV_9A"

    kubectl delete pod -n ${NS} ${podname} --wait=true --timeout=30s >/dev/null 2>&1 || true
    settle 10
  done
done

log "9A results written to ${CSV_9A}"
cat "$CSV_9A"

# ============================================================
# Test 9B: cloud-hypervisor Process RSS
# ============================================================
log ""
log "=== Test 9B: cloud-hypervisor Process RSS ==="

CSV_9B="${RESULTS}/v2-test9b-clh-rss.csv"
echo "test,round,clh_pid,VmRSS_kB,VmHWM_kB,RssAnon_kB,RssFile_kB,RssShmem_kB,Pss_kB,timestamp" > "$CSV_9B"

for round in $(seq 1 $ROUNDS); do
  podname="t9b-kata-r${round}"
  log "9B: round ${round} - deploying kata-clh pause pod..."
  gen_pause_pod "$podname" "kata-clh" "$NS" | kubectl apply -f - >/dev/null 2>&1
  wait_pod_ready "$podname" "$NS"
  settle 5

  # Find cloud-hypervisor process on host (could be cloud-hypervisor or cloud_hypervisor)
  log "  Finding cloud-hypervisor process..."
  CLH_PIDS=$(hostexec hostpod sh -c "pgrep -f 'cloud.hypervisor' || echo ''")

  if [[ -z "$CLH_PIDS" ]]; then
    log "  WARNING: No cloud-hypervisor process found!"
    echo "9B,${round},,,,,,,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV_9B"
  else
    for pid in $CLH_PIDS; do
      log "  cloud-hypervisor PID: ${pid}"

      vmrss=$(hostexec hostpod sh -c "awk '/^VmRSS:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      vmhwm=$(hostexec hostpod sh -c "awk '/^VmHWM:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssanon=$(hostexec hostpod sh -c "awk '/^RssAnon:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssfile=$(hostexec hostpod sh -c "awk '/^RssFile:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssshmem=$(hostexec hostpod sh -c "awk '/^RssShmem:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")

      pss=$(hostexec hostpod sh -c "awk '/^Pss:/ {s+=\$2} END {print s}' /proc/${pid}/smaps_rollup" 2>/dev/null || echo "")

      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      log "  VmRSS=${vmrss}kB VmHWM=${vmhwm}kB Pss=${pss}kB"
      echo "9B,${round},${pid},${vmrss},${vmhwm},${rssanon},${rssfile},${rssshmem},${pss},${ts}" >> "$CSV_9B"
    done
  fi

  kubectl delete pod -n ${NS} ${podname} --wait=true --timeout=30s >/dev/null 2>&1 || true
  settle 10
done

log "9B results written to ${CSV_9B}"
cat "$CSV_9B"

# ============================================================
# Test 9C: Cgroup Memory Accounting
# ============================================================
log ""
log "=== Test 9C: Cgroup Memory Accounting ==="

CSV_9C="${RESULTS}/v2-test9c-cgroup-vs-top.csv"
echo "test,runtime,pod_name,pod_uid,cgroup_memory_current_bytes,cgroup_memory_MiB,timestamp" > "$CSV_9C"

for runtime in runc kata-clh; do
  podname="t9c-${runtime}"
  log "9C: deploying ${runtime} pause pod..."
  gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
  wait_pod_ready "$podname" "$NS"
  settle 10

  pod_uid=$(kubectl get pod -n ${NS} ${podname} -o jsonpath='{.metadata.uid}')
  log "  Pod UID: ${pod_uid}"

  cgroup_mem=$(get_cgroup_mem "$pod_uid")
  cgroup_mib=""
  if [[ -n "$cgroup_mem" && "$cgroup_mem" =~ ^[0-9]+$ ]]; then
    cgroup_mib=$(echo "scale=2; ${cgroup_mem}/1048576" | bc)
  fi

  # Container-level breakdown
  puid=$(echo "$pod_uid" | tr '-' '_')
  log "  cgroup memory.current: ${cgroup_mem} bytes (${cgroup_mib} MiB)"

  for qos in burstable besteffort guaranteed; do
    base="/sys/fs/cgroup/kubepods.slice/kubepods-${qos}.slice/kubepods-${qos}-pod${puid}.slice"
    containers=$(hostexec hostpod sh -c "ls -d ${base}/cri-* 2>/dev/null" 2>/dev/null || echo "")
    if [[ -n "$containers" ]]; then
      log "  Container cgroups:"
      for cdir in $containers; do
        cmem=$(hostexec hostpod sh -c "cat ${cdir}/memory.current 2>/dev/null || echo N/A")
        cname=$(basename "$cdir")
        log "    ${cname:0:20}... = ${cmem} bytes"
      done
      break
    fi
  done

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "9C,${runtime},${podname},${pod_uid},${cgroup_mem},${cgroup_mib},${ts}" >> "$CSV_9C"
done

delete_test_pods
settle 30

log "9C results:"
cat "$CSV_9C"

# ============================================================
# Test 9D: Memory Overhead Under Stress
# ============================================================
log ""
log "=== Test 9D: Memory Overhead Under Stress ==="

CSV_9D="${RESULTS}/v2-test9d-stress-overhead.csv"
echo "test,runtime,stress_MiB,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp" > "$CSV_9D"

for stress_mb in 0 256 512 1024; do
  for runtime in runc kata-clh; do
    log "9D: ${runtime} stress=${stress_mb}MiB..."
    settle 10

    baseline=$(get_mem_available)
    log "  Baseline: ${baseline} MiB"

    podname="t9d-${runtime}-s${stress_mb}"
    gen_stress_pod "$podname" "$runtime" "$NS" "$stress_mb" | kubectl apply -f - >/dev/null 2>&1
    wait_pod_ready "$podname" "$NS" "180s"

    if [[ "$stress_mb" != "0" ]]; then
      settle 25
    else
      settle 10
    fi

    after=$(get_mem_available)
    delta=$((baseline - after))
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Delta: ${delta} MiB"

    echo "9D,${runtime},${stress_mb},${baseline},${after},${delta},${ts}" >> "$CSV_9D"

    delete_test_pods
    settle 30
  done
done

log "9D results:"
cat "$CSV_9D"

# ============================================================
# Test 9E: Multi-Pod Linearity
# ============================================================
log ""
log "=== Test 9E: Multi-Pod Linearity ==="

CSV_9E="${RESULTS}/v2-test9e-multi-pod-linearity.csv"
echo "test,runtime,num_pods,mem_available_before_MiB,mem_available_after_MiB,total_delta_MiB,per_pod_delta_MiB,timestamp" > "$CSV_9E"

for count in 1 2 4 8; do
  for runtime in runc kata-clh; do
    log "9E: ${runtime} count=${count}..."
    settle 10

    baseline=$(get_mem_available)
    log "  Baseline: ${baseline} MiB"

    for i in $(seq 1 $count); do
      podname="t9e-${runtime}-n${count}-p${i}"
      gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
    done

    for i in $(seq 1 $count); do
      podname="t9e-${runtime}-n${count}-p${i}"
      wait_pod_ready "$podname" "$NS"
    done

    settle 15

    after=$(get_mem_available)
    total_delta=$((baseline - after))
    per_pod=$(echo "scale=1; ${total_delta}/${count}" | bc)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  Total Delta: ${total_delta} MiB, Per-pod: ${per_pod} MiB"

    echo "9E,${runtime},${count},${baseline},${after},${total_delta},${per_pod},${ts}" >> "$CSV_9E"

    delete_test_pods
    settle 30
  done
done

log "9E results:"
cat "$CSV_9E"

# ============================================================
# Generate Summary
# ============================================================
log ""
log "=== Generating Summary ==="

SUMMARY="${RESULTS}/v2-test9-summary.md"
cat > "$SUMMARY" <<'HEADER'
# Test 9: kata-clh Memory Footprint Profiling

HEADER

cat >> "$SUMMARY" <<EOF
**Date:** $(date +%Y-%m-%d)
**Node:** ${NODE} (m8i.4xlarge, 64 GiB RAM, 16 vCPU)
**Total Node Memory:** ${MEM_TOTAL} MiB
**Runtimes:** runc (baseline) vs kata-clh (cloud-hypervisor)
**Base Image:** ${PAUSE_IMAGE}

---

## 9A: Single Pod Idle Memory Delta

$(cat "$CSV_9A")

---

## 9B: cloud-hypervisor Process RSS

$(cat "$CSV_9B")

---

## 9C: Cgroup Memory Accounting

$(cat "$CSV_9C")

---

## 9D: Memory Overhead Under Stress

$(cat "$CSV_9D")

---

## 9E: Multi-Pod Linearity

$(cat "$CSV_9E")

---

*Results files:*
- \`v2-test9a-idle-memory-delta.csv\`
- \`v2-test9b-clh-rss.csv\`
- \`v2-test9c-cgroup-vs-top.csv\`
- \`v2-test9d-stress-overhead.csv\`
- \`v2-test9e-multi-pod-linearity.csv\`
EOF

log "Summary written to ${SUMMARY}"

# ============================================================
# Cleanup
# ============================================================
log ""
log "=== Cleanup ==="
cleanup_ns
log "All Test 9 subtests complete!"
log "Results in: ${RESULTS}/v2-test9*.csv"

# Notification
openclaw system event --text 'Done: Test 9 kata-clh memory footprint profiling complete' --mode now 2>/dev/null || true

}

# Run main, tee all output
main 2>&1 | tee "${LOGFILE}"
