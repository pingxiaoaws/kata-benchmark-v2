#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test 7: Runtime Memory Footprint Profiling
# kata-qemu vs runc memory overhead measurement
# ============================================================

# Replace with your own node FQDN (e.g., ip-x-x-x-x.region.compute.internal)
NODE="node-2"
NODE_SHORT="node-2"
NS="bench7"
RESULTS="/home/ec2-user/benchmark/results"
PAUSE_IMAGE="registry.k8s.io/pause:3.10"
TAINT_KEY="kata-benchmark"
TAINT_VAL="true"
ROUNDS=3

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

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
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: hostroot
      mountPath: /host
  volumes:
  - name: hostroot
    hostPath:
      path: /
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
  local podname="$1"
  hostexec "$podname" sh -c "awk '/MemAvailable/ {printf \"%.0f\", \$2/1024}' /proc/meminfo"
}

# ── Helper: get MemFree + Buffers + Cached (used for delta) ──
get_mem_free_total() {
  local podname="$1"
  hostexec "$podname" sh -c "awk '/^MemFree:|^Buffers:|^Cached:/ {s+=\$2} END {printf \"%.0f\", s/1024}' /proc/meminfo"
}

# ── Helper: generate pause pod YAML ──
gen_pause_pod() {
  local name="$1" runtime="$2" ns="$3" mem_req="${4:-64Mi}" mem_lim="${5:-128Mi}"
  local rc_line=""
  if [[ "$runtime" != "runc" ]]; then
    rc_line="  runtimeClassName: ${runtime}"
  fi
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: bench7
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
  local rc_line=""
  local mem_lim="2Gi"
  if [[ "$runtime" != "runc" ]]; then
    rc_line="  runtimeClassName: ${runtime}"
  fi
  # stress-ng command: allocate stress_mb of memory
  local cmd="stress-ng --vm 1 --vm-bytes ${stress_mb}M --vm-hang 300 --timeout 300s"
  if [[ "$stress_mb" == "0" ]]; then
    cmd="sleep 300"
  fi
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: bench7-stress
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
    command: ["sh", "-c", "${cmd}"]
    resources:
      requests:
        memory: "2Gi"
        cpu: "100m"
      limits:
        memory: "2Gi"
        cpu: "500m"
  terminationGracePeriodSeconds: 0
EOF
}

cleanup_ns() {
  kubectl delete namespace ${NS} --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  sleep 3
}

wait_pod_ready() {
  local name="$1" ns="$2" timeout="${3:-120s}"
  kubectl wait -n ${ns} pod/${name} --for=condition=Ready --timeout=${timeout} >/dev/null 2>&1
}

settle() {
  log "Settling for $1 seconds..."
  sleep "$1"
}

# ============================================================
log "=== Test 7: Runtime Memory Footprint Profiling ==="
log "Target node: ${NODE}"

# Create namespace
cleanup_ns
kubectl create namespace ${NS} >/dev/null 2>&1

# Deploy host access pod
log "Deploying host access pod..."
deploy_hostpod "hostpod"

# Quick sanity check
MEM_TOTAL=$(hostexec hostpod sh -c "awk '/MemTotal/ {printf \"%.0f\", \$2/1024}' /proc/meminfo")
log "Node total memory: ${MEM_TOTAL} MiB"

# ============================================================
# Test 7A: Single Pod Idle Memory Delta
# ============================================================
log ""
log "=== Test 7A: Single Pod Idle Memory Delta ==="

CSV_7A="${RESULTS}/v2-test7a-idle-memory-delta.csv"
echo "test,runtime,round,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp" > "$CSV_7A"

for runtime in runc kata-qemu; do
  for round in $(seq 1 $ROUNDS); do
    log "7A: ${runtime} round ${round} - measuring baseline..."
    settle 10

    baseline=$(get_mem_available hostpod)
    log "  Baseline MemAvailable: ${baseline} MiB"

    # Deploy pause pod
    podname="t7a-${runtime}-r${round}"
    gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
    wait_pod_ready "$podname" "$NS"

    settle 10  # let memory settle

    after=$(get_mem_available hostpod)
    delta=$((baseline - after))
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Delta: ${delta} MiB"

    echo "7A,${runtime},${round},${baseline},${after},${delta},${ts}" >> "$CSV_7A"

    # Clean up pod
    kubectl delete pod -n ${NS} ${podname} --wait=true --timeout=30s >/dev/null 2>&1 || true
    settle 10  # let memory reclaim
  done
done

log "7A results written to ${CSV_7A}"
cat "$CSV_7A"

# ============================================================
# Test 7B: QEMU Process RSS
# ============================================================
log ""
log "=== Test 7B: QEMU Process RSS ==="

CSV_7B="${RESULTS}/v2-test7b-qemu-rss.csv"
echo "test,round,qemu_pid,VmRSS_kB,VmHWM_kB,RssAnon_kB,RssFile_kB,RssShmem_kB,Pss_kB,timestamp" > "$CSV_7B"

for round in $(seq 1 $ROUNDS); do
  podname="t7b-kata-r${round}"
  log "7B: round ${round} - deploying kata-qemu pause pod..."
  gen_pause_pod "$podname" "kata-qemu" "$NS" | kubectl apply -f - >/dev/null 2>&1
  wait_pod_ready "$podname" "$NS"
  settle 5

  # Find qemu process on host
  log "  Finding qemu process..."
  QEMU_PIDS=$(hostexec hostpod sh -c "pgrep -f 'qemu-system' || echo ''")

  if [[ -z "$QEMU_PIDS" ]]; then
    log "  WARNING: No qemu process found!"
    echo "7B,${round},,,,,,,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV_7B"
  else
    for pid in $QEMU_PIDS; do
      log "  QEMU PID: ${pid}"

      # Get VmRSS, VmHWM from /proc/pid/status
      vmrss=$(hostexec hostpod sh -c "awk '/^VmRSS:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      vmhwm=$(hostexec hostpod sh -c "awk '/^VmHWM:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssanon=$(hostexec hostpod sh -c "awk '/^RssAnon:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssfile=$(hostexec hostpod sh -c "awk '/^RssFile:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")
      rssshmem=$(hostexec hostpod sh -c "awk '/^RssShmem:/ {print \$2}' /proc/${pid}/status" 2>/dev/null || echo "")

      # Try smaps_rollup for PSS
      pss=$(hostexec hostpod sh -c "awk '/^Pss:/ {s+=\$2} END {print s}' /proc/${pid}/smaps_rollup" 2>/dev/null || echo "")

      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      log "  VmRSS=${vmrss}kB VmHWM=${vmhwm}kB Pss=${pss}kB"
      echo "7B,${round},${pid},${vmrss},${vmhwm},${rssanon},${rssfile},${rssshmem},${pss},${ts}" >> "$CSV_7B"
    done
  fi

  # Clean up
  kubectl delete pod -n ${NS} ${podname} --wait=true --timeout=30s >/dev/null 2>&1 || true
  settle 10
done

log "7B results written to ${CSV_7B}"
cat "$CSV_7B"

# ============================================================
# Test 7C: Cgroup Memory vs kubectl top
# ============================================================
log ""
log "=== Test 7C: Cgroup Memory vs kubectl top ==="

CSV_7C="${RESULTS}/v2-test7c-cgroup-vs-top.csv"
echo "test,runtime,pod_name,kubectl_top_MiB,cgroup_memory_current_bytes,cgroup_memory_MiB,overhead_MiB,timestamp" > "$CSV_7C"

for runtime in runc kata-qemu; do
  podname="t7c-${runtime}"
  log "7C: deploying ${runtime} pause pod..."
  gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
  wait_pod_ready "$podname" "$NS"
  settle 15  # let metrics settle

  # kubectl top
  top_output=$(kubectl top pod -n ${NS} ${podname} --no-headers 2>/dev/null || echo "")
  top_mem=""
  if [[ -n "$top_output" ]]; then
    top_mem=$(echo "$top_output" | awk '{print $3}' | sed 's/Mi//')
  fi
  log "  kubectl top: ${top_mem} MiB"

  # Find cgroup path on host
  pod_uid=$(kubectl get pod -n ${NS} ${podname} -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
  log "  Pod UID: ${pod_uid}"

  # Try to find cgroup memory
  cgroup_mem=""
  if [[ -n "$pod_uid" ]]; then
    pod_uid_path=$(echo "$pod_uid" | tr '-' '_')
    # Try cgroupv2
    cgroup_mem=$(hostexec hostpod sh -c "
      find /sys/fs/cgroup -name '*${pod_uid}*' -path '*/memory.current' 2>/dev/null | head -1 | xargs cat 2>/dev/null || \
      find /sys/fs/cgroup -path '*pod${pod_uid}*' -name 'memory.current' 2>/dev/null | head -1 | xargs cat 2>/dev/null || \
      echo ''
    " 2>/dev/null || echo "")

    # If cgroupv2 didn't work, try finding the cgroup path differently
    if [[ -z "$cgroup_mem" ]]; then
      cgroup_mem=$(hostexec hostpod sh -c "
        for d in /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/*${pod_uid}*/memory.current \
                 /sys/fs/cgroup/kubepods.slice/kubepods-guaranteed.slice/*${pod_uid}*/memory.current \
                 /sys/fs/cgroup/kubepods/burstable/pod${pod_uid}/memory.current \
                 /sys/fs/cgroup/kubepods/pod${pod_uid}/memory.current; do
          if [ -f \"\$d\" ]; then cat \"\$d\"; exit 0; fi
        done
        echo ''
      " 2>/dev/null || echo "")
    fi
  fi

  cgroup_mib=""
  overhead=""
  if [[ -n "$cgroup_mem" && "$cgroup_mem" =~ ^[0-9]+$ ]]; then
    cgroup_mib=$(echo "scale=1; ${cgroup_mem}/1048576" | bc)
    if [[ -n "$top_mem" && "$top_mem" =~ ^[0-9]+$ ]]; then
      overhead=$(echo "scale=1; ${cgroup_mib} - ${top_mem}" | bc)
    fi
  fi

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "  cgroup memory.current: ${cgroup_mem} bytes (${cgroup_mib} MiB), overhead: ${overhead} MiB"
  echo "7C,${runtime},${podname},${top_mem},${cgroup_mem},${cgroup_mib},${overhead},${ts}" >> "$CSV_7C"
done

# Cleanup 7C pods
kubectl delete pod -n ${NS} t7c-runc t7c-kata-qemu --wait=true --timeout=30s >/dev/null 2>&1 || true
settle 10

log "7C results written to ${CSV_7C}"
cat "$CSV_7C"

# ============================================================
# Test 7D: Memory overhead under different stress levels
# ============================================================
log ""
log "=== Test 7D: Memory Overhead Under Stress ==="

CSV_7D="${RESULTS}/v2-test7d-stress-overhead.csv"
echo "test,runtime,stress_MiB,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp" > "$CSV_7D"

for stress_mb in 0 256 512 1024; do
  for runtime in runc kata-qemu; do
    log "7D: ${runtime} stress=${stress_mb}MiB - measuring baseline..."
    settle 10

    baseline=$(get_mem_available hostpod)
    log "  Baseline MemAvailable: ${baseline} MiB"

    podname="t7d-${runtime}-s${stress_mb}"
    gen_stress_pod "$podname" "$runtime" "$NS" "$stress_mb" | kubectl apply -f - >/dev/null 2>&1
    wait_pod_ready "$podname" "$NS" "180s"

    settle 20  # let stress-ng allocate and settle

    after=$(get_mem_available hostpod)
    delta=$((baseline - after))
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Delta: ${delta} MiB (stress=${stress_mb}, runtime=${runtime})"

    echo "7D,${runtime},${stress_mb},${baseline},${after},${delta},${ts}" >> "$CSV_7D"

    # Clean up
    kubectl delete pod -n ${NS} ${podname} --wait=true --timeout=30s >/dev/null 2>&1 || true
    settle 15
  done
done

log "7D results written to ${CSV_7D}"
cat "$CSV_7D"

# ============================================================
# Test 7E: Multi-Pod Linearity
# ============================================================
log ""
log "=== Test 7E: Multi-Pod Linearity ==="

CSV_7E="${RESULTS}/v2-test7e-multi-pod-linearity.csv"
echo "test,runtime,num_pods,mem_available_before_MiB,mem_available_after_MiB,total_delta_MiB,per_pod_delta_MiB,timestamp" > "$CSV_7E"

for count in 1 2 4 8; do
  for runtime in runc kata-qemu; do
    log "7E: ${runtime} count=${count} - measuring baseline..."
    settle 10

    baseline=$(get_mem_available hostpod)
    log "  Baseline MemAvailable: ${baseline} MiB"

    # Deploy N pods
    for i in $(seq 1 $count); do
      podname="t7e-${runtime}-n${count}-p${i}"
      gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
    done

    # Wait for all
    for i in $(seq 1 $count); do
      podname="t7e-${runtime}-n${count}-p${i}"
      wait_pod_ready "$podname" "$NS"
    done

    settle 15  # let memory settle

    after=$(get_mem_available hostpod)
    total_delta=$((baseline - after))
    per_pod=$(echo "scale=1; ${total_delta}/${count}" | bc)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Total Delta: ${total_delta} MiB, Per-pod: ${per_pod} MiB"

    echo "7E,${runtime},${count},${baseline},${after},${total_delta},${per_pod},${ts}" >> "$CSV_7E"

    # Clean up all pods
    for i in $(seq 1 $count); do
      podname="t7e-${runtime}-n${count}-p${i}"
      kubectl delete pod -n ${NS} ${podname} --wait=false >/dev/null 2>&1 || true
    done
    # Wait for all deleted
    sleep 5
    kubectl wait -n ${NS} --for=delete pod -l "app=bench7,runtime=${runtime}" --timeout=60s >/dev/null 2>&1 || true
    settle 15
  done
done

log "7E results written to ${CSV_7E}"
cat "$CSV_7E"

# ============================================================
# Cleanup
# ============================================================
log ""
log "=== Cleanup ==="
cleanup_ns
log "All Test 7 subtests complete!"
log "Results in: ${RESULTS}/v2-test7*.csv"
