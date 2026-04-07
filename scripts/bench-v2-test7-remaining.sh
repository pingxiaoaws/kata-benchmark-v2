#!/usr/bin/env bash
set -euo pipefail

NODE="ip-172-31-19-254.us-west-2.compute.internal"
NS="bench7"
RESULTS="/home/ec2-user/benchmark/results"
PAUSE_IMAGE="registry.k8s.io/pause:3.10"
TAINT_KEY="kata-benchmark"
TAINT_VAL="true"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

hostexec() {
  kubectl exec -n ${NS} hostpod -- nsenter -t 1 -m -u -i -n -p -- "$@"
}

get_mem_available() {
  hostexec sh -c "awk '/MemAvailable/ {printf \"%.0f\", \$2/1024}' /proc/meminfo"
}

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

wait_pod_ready() {
  kubectl wait -n "$2" "pod/$1" --for=condition=Ready --timeout="${3:-120s}" >/dev/null 2>&1
}

delete_test_pods() {
  # Delete all bench7 pods except hostpod
  kubectl get pods -n ${NS} --no-headers -o name 2>/dev/null | grep -v hostpod | while read p; do
    kubectl delete -n ${NS} "$p" --force --grace-period=0 2>/dev/null || true
  done
  sleep 5
}

get_cgroup_mem() {
  local pod_uid="$1"
  local puid=$(echo "$pod_uid" | tr '-' '_')
  # Try burstable first, then besteffort, then guaranteed
  for qos in burstable besteffort guaranteed; do
    local path="/sys/fs/cgroup/kubepods.slice/kubepods-${qos}.slice/kubepods-${qos}-pod${puid}.slice/memory.current"
    local val=$(hostexec sh -c "cat ${path} 2>/dev/null || echo ''" 2>/dev/null || echo "")
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      echo "$val"
      return
    fi
  done
  # Try top-level
  local path="/sys/fs/cgroup/kubepods.slice/kubepods-pod${puid}.slice/memory.current"
  hostexec sh -c "cat ${path} 2>/dev/null || echo ''" 2>/dev/null || echo ""
}

settle() { log "Settling ${1}s..."; sleep "$1"; }

# Verify hostpod is running
kubectl get pod -n ${NS} hostpod --no-headers 2>&1

# ============================================================
# Test 7C: Cgroup Memory vs kubectl top
# ============================================================
log "=== Test 7C: Cgroup Memory vs kubectl top ==="
CSV_7C="${RESULTS}/v2-test7c-cgroup-vs-top.csv"
echo "test,runtime,pod_name,pod_uid,cgroup_memory_current_bytes,cgroup_memory_MiB,timestamp" > "$CSV_7C"

for runtime in runc kata-qemu; do
  podname="t7c-${runtime}"
  log "7C: deploying ${runtime} pause pod..."
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

  # Also get per-container cgroup breakdown
  puid=$(echo "$pod_uid" | tr '-' '_')
  log "  cgroup memory.current: ${cgroup_mem} bytes (${cgroup_mib} MiB)"

  # Get container-level breakdown
  for qos in burstable besteffort guaranteed; do
    base="/sys/fs/cgroup/kubepods.slice/kubepods-${qos}.slice/kubepods-${qos}-pod${puid}.slice"
    containers=$(hostexec sh -c "ls -d ${base}/cri-* 2>/dev/null" 2>/dev/null || echo "")
    if [[ -n "$containers" ]]; then
      log "  Container cgroups:"
      for cdir in $containers; do
        cmem=$(hostexec sh -c "cat ${cdir}/memory.current 2>/dev/null || echo N/A")
        cname=$(basename "$cdir")
        log "    ${cname:0:20}... = ${cmem} bytes"
      done
      break
    fi
  done

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "7C,${runtime},${podname},${pod_uid},${cgroup_mem},${cgroup_mib},${ts}" >> "$CSV_7C"
done

delete_test_pods
settle 10

log "7C results:"
cat "$CSV_7C"

# ============================================================
# Test 7D: Memory Overhead Under Stress
# ============================================================
log ""
log "=== Test 7D: Memory Overhead Under Stress ==="
CSV_7D="${RESULTS}/v2-test7d-stress-overhead.csv"
echo "test,runtime,stress_MiB,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp" > "$CSV_7D"

# Use a stress-ng pod that actually works
gen_stress_pod() {
  local name="$1" runtime="$2" ns="$3" stress_mb="$4"
  local rc_line="" mem_lim="2Gi"
  [[ "$runtime" != "runc" ]] && rc_line="  runtimeClassName: ${runtime}"

  if [[ "$stress_mb" == "0" ]]; then
    # For zero stress, just use pause container
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

for stress_mb in 0 256 512 1024; do
  for runtime in runc kata-qemu; do
    log "7D: ${runtime} stress=${stress_mb}MiB..."
    settle 10

    baseline=$(get_mem_available)
    log "  Baseline: ${baseline} MiB"

    podname="t7d-${runtime}-s${stress_mb}"
    gen_stress_pod "$podname" "$runtime" "$NS" "$stress_mb" | kubectl apply -f - >/dev/null 2>&1
    wait_pod_ready "$podname" "$NS" "180s"

    if [[ "$stress_mb" != "0" ]]; then
      settle 25  # wait for stress-ng to allocate
    else
      settle 10
    fi

    after=$(get_mem_available)
    delta=$((baseline - after))
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  After: ${after} MiB, Delta: ${delta} MiB"

    echo "7D,${runtime},${stress_mb},${baseline},${after},${delta},${ts}" >> "$CSV_7D"

    delete_test_pods
    settle 10
  done
done

log "7D results:"
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
    log "7E: ${runtime} count=${count}..."
    settle 10

    baseline=$(get_mem_available)
    log "  Baseline: ${baseline} MiB"

    for i in $(seq 1 $count); do
      podname="t7e-${runtime}-n${count}-p${i}"
      gen_pause_pod "$podname" "$runtime" "$NS" | kubectl apply -f - >/dev/null 2>&1
    done

    for i in $(seq 1 $count); do
      podname="t7e-${runtime}-n${count}-p${i}"
      wait_pod_ready "$podname" "$NS"
    done

    settle 15

    after=$(get_mem_available)
    total_delta=$((baseline - after))
    per_pod=$(echo "scale=1; ${total_delta}/${count}" | bc)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "  Total Delta: ${total_delta} MiB, Per-pod: ${per_pod} MiB"

    echo "7E,${runtime},${count},${baseline},${after},${total_delta},${per_pod},${ts}" >> "$CSV_7E"

    delete_test_pods
    settle 15
  done
done

log "7E results:"
cat "$CSV_7E"

log ""
log "=== All remaining tests complete! ==="
