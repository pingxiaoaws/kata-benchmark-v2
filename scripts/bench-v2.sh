#!/usr/bin/env bash
set -euo pipefail

# === OpenClaw Kata Benchmark v2 ===
# Operator v0.22.2, EKS 1.34, test-s4 cluster

RESULTS_DIR="/home/ec2-user/benchmark/results"
mkdir -p "$RESULTS_DIR"

IMAGE_REPO="ghcr.io/openclaw/openclaw"
IMAGE_TAG="latest"

# Nodes
UNTAINTED_NODE="ip-172-31-29-155.us-west-2.compute.internal"
R8I_NODE="ip-172-31-18-5.us-west-2.compute.internal"

# m8i.4xlarge nodes with kata-benchmark taint (for Test 2/3)
TAINTED_NODES=(
  "ip-172-31-18-241.us-west-2.compute.internal"
  "ip-172-31-19-254.us-west-2.compute.internal"
  "ip-172-31-19-97.us-west-2.compute.internal"
  "ip-172-31-21-152.us-west-2.compute.internal"
  "ip-172-31-22-253.us-west-2.compute.internal"
  "ip-172-31-24-12.us-west-2.compute.internal"
  "ip-172-31-25-251.us-west-2.compute.internal"
  "ip-172-31-27-93.us-west-2.compute.internal"
)
# Additional untainted m8i for Test 3
UNTAINTED_NODE2="ip-172-31-28-206.us-west-2.compute.internal"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# Generate OpenClawInstance YAML
# Args: name, namespace, runtime(runc|kata-qemu|kata-clh), node(optional), toleration_key(optional), cpu_req(optional), cpu_lim(optional)
gen_yaml() {
  local name="$1" ns="$2" runtime="$3" node="${4:-}" tol_key="${5:-}"
  local cpu_req="${6:-800m}" cpu_lim="${7:-1}"

  local runtime_line=""
  if [[ "$runtime" != "runc" ]]; then
    runtime_line="    runtimeClassName: $runtime"
  fi

  local node_selector="    nodeSelector:
      workload-type: kata"
  if [[ -n "$node" ]]; then
    node_selector="    nodeSelector:
      workload-type: kata
      kubernetes.io/hostname: $node"
  fi

  local tolerations=""
  if [[ -n "$tol_key" ]]; then
    tolerations="    tolerations:
      - key: $tol_key
        operator: Equal
        value: \"true\"
        effect: NoSchedule"
  fi

  cat <<EOF
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: $name
  namespace: $ns
spec:
  image:
    pullPolicy: IfNotPresent
    repository: $IMAGE_REPO
    tag: $IMAGE_TAG
  resources:
    requests:
      cpu: $cpu_req
      memory: 2Gi
    limits:
      cpu: "$cpu_lim"
      memory: 3Gi
  storage:
    persistence:
      enabled: true
      size: 10Gi
      accessModes:
        - ReadWriteOnce
      storageClass: gp3
  env:
    - name: AWS_REGION
      value: us-west-2
    - name: AWS_DEFAULT_REGION
      value: us-west-2
  networking:
    ingress:
      enabled: false
    service:
      type: ClusterIP
  selfConfigure:
    enabled: false
  availability:
$runtime_line
$node_selector
$tolerations
  security:
    containerSecurityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      readOnlyRootFilesystem: false
    podSecurityContext:
      fsGroup: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      runAsUser: 1000
    rbac:
      createServiceAccount: true
    networkPolicy:
      allowDNS: true
      enabled: true
  gateway: {}
  observability:
    logging:
      format: json
      level: info
  chromium:
    enabled: false
  ollama:
    enabled: false
  tailscale:
    enabled: false
  webTerminal:
    enabled: false
EOF
}

# Create instance, measure boot time
# Writes result to MEASURE_RESULT variable: "boot_sec,node,kernel" or "-1"
# Args: name, namespace, runtime, node(optional), toleration_key(optional)
MEASURE_RESULT=""
create_and_measure() {
  local name="$1" ns="$2" runtime="$3" node="${4:-}" tol_key="${5:-}"
  local pod_name="${name}-0"
  MEASURE_RESULT="-1"

  log "Creating namespace $ns"
  kubectl create namespace "$ns" >/dev/null 2>&1 || true

  local yaml
  yaml=$(gen_yaml "$name" "$ns" "$runtime" "$node" "$tol_key")

  log "Applying OpenClawInstance $name (runtime=$runtime)"
  local t1
  t1=$(date +%s%N)
  echo "$yaml" | kubectl apply -f - >/dev/null 2>&1

  log "Waiting for pod $pod_name to be Ready (timeout 300s)..."
  if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$ns" --timeout=300s >/dev/null 2>&1; then
    log "Direct pod wait failed, checking pod status..."
    kubectl get pods -n "$ns" -o wide >&2 || true
    sleep 10
    if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$ns" --timeout=300s >/dev/null 2>&1; then
      log "ERROR: Pod $pod_name did not become Ready"
      return 1
    fi
  fi
  local t2
  t2=$(date +%s%N)

  local boot_ms=$(( (t2 - t1) / 1000000 ))
  local boot_sec
  boot_sec=$(echo "scale=2; $boot_ms / 1000" | bc)

  local actual_node
  actual_node=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  local kernel
  kernel=$(kubectl exec "$pod_name" -n "$ns" -c openclaw -- uname -r 2>/dev/null || echo "N/A")

  log "Boot: ${boot_sec}s | Node: $actual_node | Kernel: $kernel"
  MEASURE_RESULT="${boot_sec},${actual_node},${kernel}"
}

# Cleanup namespace
cleanup_ns() {
  local ns="$1"
  log "Deleting namespace $ns"
  kubectl delete namespace "$ns" --wait=false 2>/dev/null || true
}

# ============================================================
# TEST 1: Single Pod Cold Boot
# ============================================================
run_test1() {
  log "=== TEST 1: Single Pod Cold Boot ==="
  local csv="$RESULTS_DIR/v2-test1-boot-time.csv"
  echo "runtime,iteration,boot_time_sec,node,kernel,timestamp" > "$csv"

  for runtime in runc kata-qemu kata-clh; do
    for i in $(seq 1 5); do
      local ns="bench-t1-${runtime}-${i}"
      local name="bench-t1-${runtime}-${i}"
      local ts
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

      log "--- Test1: $runtime iteration $i ---"
      create_and_measure "$name" "$ns" "$runtime" "" "kata-benchmark"

      if [[ "$MEASURE_RESULT" != "-1" ]]; then
        local boot_sec node kernel
        boot_sec=$(echo "$MEASURE_RESULT" | cut -d, -f1)
        node=$(echo "$MEASURE_RESULT" | cut -d, -f2)
        kernel=$(echo "$MEASURE_RESULT" | cut -d, -f3)
        echo "$runtime,$i,$boot_sec,$node,$kernel,$ts" >> "$csv"
      else
        echo "$runtime,$i,FAILED,,,${ts}" >> "$csv"
      fi

      # Cleanup after each iteration
      cleanup_ns "$ns"
      # Small pause between iterations
      sleep 5
    done
  done

  log "Test 1 complete. Results: $csv"
  cat "$csv" >&2
}

# ============================================================
# TEST 2: Saturated Node Boot
# ============================================================
run_test2() {
  log "=== TEST 2: Saturated Node Boot ==="
  local csv="$RESULTS_DIR/v2-test2-saturated-boot-time.csv"
  echo "runtime,iteration,boot_time_sec,node,kernel,num_existing_pods,timestamp" > "$csv"

  local target_node="${TAINTED_NODES[0]}"  # ip-172-31-18-241
  log "Target node: $target_node"

  for runtime in runc kata-qemu kata-clh; do
    log "--- Test2: Saturating node with $runtime ---"

    # Create 18 pods to saturate (800m CPU each, m8i.4xlarge = 16 vCPU)
    # Actually 16 vCPU with some reserved, let's do 15 to be safe
    local fill_count=15
    local fill_ns="bench-t2-fill-${runtime}"

    for f in $(seq 1 $fill_count); do
      local fname="bench-t2-f${f}-${runtime}"
      local fns="bench-t2-f${f}-${runtime}"
      kubectl create namespace "$fns" >/dev/null 2>&1 || true
      local yaml
      yaml=$(gen_yaml "$fname" "$fns" "$runtime" "$target_node" "kata-benchmark")
      echo "$yaml" | kubectl apply -f - >/dev/null 2>&1 &
    done
    wait

    log "Waiting for fill pods to be ready..."
    local ready_count=0
    for attempt in $(seq 1 60); do
      ready_count=0
      for f in $(seq 1 $fill_count); do
        local fns="bench-t2-f${f}-${runtime}"
        local fname="bench-t2-f${f}-${runtime}"
        local phase
        phase=$(kubectl get pod "${fname}-0" -n "$fns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        if [[ "$phase" == "Running" ]]; then
          ((ready_count++)) || true
        fi
      done
      log "Fill pods ready: $ready_count / $fill_count"
      if [[ $ready_count -ge $fill_count ]]; then
        break
      fi
      sleep 10
    done

    log "Fill complete: $ready_count pods running on $target_node"

    # Now measure the N+1 pod
    for i in $(seq 1 3); do
      local ns="bench-t2-extra-${runtime}-${i}"
      local name="bench-t2-extra-${runtime}-${i}"
      local ts
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

      log "--- Test2: $runtime extra pod $i ---"
      create_and_measure "$name" "$ns" "$runtime" "$target_node" "kata-benchmark"

      if [[ "$MEASURE_RESULT" != "-1" ]]; then
        local boot_sec node kernel
        boot_sec=$(echo "$MEASURE_RESULT" | cut -d, -f1)
        node=$(echo "$MEASURE_RESULT" | cut -d, -f2)
        kernel=$(echo "$MEASURE_RESULT" | cut -d, -f3)
        echo "$runtime,$i,$boot_sec,$node,$kernel,$ready_count,$ts" >> "$csv"
      else
        echo "$runtime,$i,FAILED,,,${ready_count},${ts}" >> "$csv"
      fi
      cleanup_ns "$ns"
      sleep 3
    done

    # Cleanup fill pods
    log "Cleaning up fill pods for $runtime..."
    for f in $(seq 1 $fill_count); do
      local fns="bench-t2-f${f}-${runtime}"
      cleanup_ns "$fns" &
    done
    wait
    log "Waiting for fill namespaces to terminate..."
    sleep 30
  done

  log "Test 2 complete. Results: $csv"
  cat "$csv" >&2
}

# ============================================================
# TEST 3: 10-Node Full Load Boot
# ============================================================
run_test3() {
  log "=== TEST 3: 10-Node Full Load Boot ==="
  local csv="$RESULTS_DIR/v2-test3-multi-node-boot-time.csv"
  echo "runtime,iteration,boot_time_sec,node,kernel,total_fill_pods,timestamp" > "$csv"

  # All 10 m8i nodes: 8 tainted + 2 untainted
  local ALL_M8I_NODES=("${TAINTED_NODES[@]}" "$UNTAINTED_NODE" "$UNTAINTED_NODE2")

  for runtime in runc kata-qemu kata-clh; do
    log "--- Test3: Filling 10 nodes with $runtime ---"

    # Fill each node with ~12 pods (to leave some room but create pressure)
    local pods_per_node=12
    local total=0
    local counter=0

    for node in "${ALL_M8I_NODES[@]}"; do
      for p in $(seq 1 $pods_per_node); do
        ((counter++)) || true
        local fname="bench-t3-${runtime}-${counter}"
        local fns="bench-t3-${runtime}-${counter}"
        local tol_key=""
        # Check if node is tainted
        case "$node" in
          ip-172-31-18-241*|ip-172-31-19-254*|ip-172-31-19-97*|ip-172-31-21-152*|ip-172-31-22-253*|ip-172-31-24-12*|ip-172-31-25-251*|ip-172-31-27-93*)
            tol_key="kata-benchmark"
            ;;
        esac
        kubectl create namespace "$fns" >/dev/null 2>&1 || true
        local yaml
        yaml=$(gen_yaml "$fname" "$fns" "$runtime" "$node" "$tol_key")
        echo "$yaml" | kubectl apply -f - >/dev/null 2>&1 &
        # Limit parallel kubectl applies
        if (( counter % 20 == 0 )); then
          wait
        fi
      done
    done
    wait
    total=$counter

    log "Created $total fill pods across 10 nodes, waiting for readiness..."
    sleep 60

    # Check how many are running
    local running
    running=$(kubectl get pods -A -l app.kubernetes.io/managed-by=openclaw-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    log "Running pods: $running / $total"

    # Now measure extra pod
    for i in $(seq 1 3); do
      local ns="bench-t3-extra-${runtime}-${i}"
      local name="bench-t3-extra-${runtime}-${i}"
      local ts
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

      log "--- Test3: $runtime extra pod $i ---"
      create_and_measure "$name" "$ns" "$runtime" "" "kata-benchmark"

      if [[ "$MEASURE_RESULT" != "-1" ]]; then
        local boot_sec node kernel
        boot_sec=$(echo "$MEASURE_RESULT" | cut -d, -f1)
        node=$(echo "$MEASURE_RESULT" | cut -d, -f2)
        kernel=$(echo "$MEASURE_RESULT" | cut -d, -f3)
        echo "$runtime,$i,$boot_sec,$node,$kernel,$total,$ts" >> "$csv"
      else
        echo "$runtime,$i,FAILED,,,${total},${ts}" >> "$csv"
      fi
      cleanup_ns "$ns"
      sleep 3
    done

    # Cleanup all fill pods
    log "Cleaning up $total fill pods for $runtime..."
    for c in $(seq 1 $total); do
      local fns="bench-t3-${runtime}-${c}"
      cleanup_ns "$fns" &
      if (( c % 20 == 0 )); then
        wait
      fi
    done
    wait
    log "Waiting for namespaces to terminate..."
    sleep 60
  done

  log "Test 3 complete. Results: $csv"
  cat "$csv" >&2
}

# ============================================================
# TEST 4: Runtime Comparison
# ============================================================
run_test4() {
  log "=== TEST 4: Runtime Comparison ==="
  local csv="$RESULTS_DIR/v2-test4-runtime-comparison.csv"
  echo "runtime,boot_time_sec,node,kernel,gateway_status,cpu_usage,memory_usage,timestamp" > "$csv"

  local target_node="$UNTAINTED_NODE"

  for runtime in runc kata-qemu kata-clh; do
    local ns="bench-t4-${runtime}"
    local name="bench-t4-${runtime}"
    local pod_name="${name}-0"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    log "--- Test4: Creating $runtime instance ---"
    create_and_measure "$name" "$ns" "$runtime" "$target_node" ""

    if [[ "$MEASURE_RESULT" == "-1" ]]; then
      echo "$runtime,FAILED,,,,,,${ts}" >> "$csv"
      continue
    fi

    local boot_sec node kernel
    boot_sec=$(echo "$MEASURE_RESULT" | cut -d, -f1)
    node=$(echo "$MEASURE_RESULT" | cut -d, -f2)
    kernel=$(echo "$MEASURE_RESULT" | cut -d, -f3)

    # Wait for gateway to be ready
    sleep 10

    # Test gateway
    local pod_ip
    pod_ip=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.status.podIP}')
    local gw_status="N/A"
    if [[ -n "$pod_ip" ]]; then
      gw_status=$(kubectl exec "$pod_name" -n "$ns" -c openclaw -- curl -s -o /dev/null -w '%{http_code}' "http://localhost:18789/" 2>/dev/null || echo "FAIL")
    fi
    log "Gateway status: $gw_status"

    # Get resource usage via kubectl top
    sleep 5
    local cpu_usage mem_usage
    local top_output
    top_output=$(kubectl top pod "$pod_name" -n "$ns" --containers 2>/dev/null || echo "N/A N/A N/A")
    cpu_usage=$(echo "$top_output" | grep openclaw | awk '{print $3}' || echo "N/A")
    mem_usage=$(echo "$top_output" | grep openclaw | awk '{print $4}' || echo "N/A")
    log "CPU: $cpu_usage, Memory: $mem_usage"

    echo "$runtime,$boot_sec,$node,$kernel,$gw_status,$cpu_usage,$mem_usage,$ts" >> "$csv"
  done

  # Keep pods running briefly for comparison, then cleanup
  log "Pods running for comparison. Collecting final metrics..."
  sleep 15
  for runtime in runc kata-qemu kata-clh; do
    local ns="bench-t4-${runtime}"
    local pod_name="bench-t4-${runtime}-0"
    log "--- $runtime final metrics ---"
    kubectl top pod "$pod_name" -n "$ns" --containers 2>/dev/null || true
  done

  # Cleanup
  for runtime in runc kata-qemu kata-clh; do
    cleanup_ns "bench-t4-${runtime}"
  done

  log "Test 4 complete. Results: $csv"
  cat "$csv" >&2
}

# ============================================================
# TEST 5: R8i Oversell Stability (2h monitoring)
# ============================================================
run_test5() {
  log "=== TEST 5: R8i Oversell Stability ==="
  local csv="$RESULTS_DIR/v2-test5-oversell-stability.csv"
  echo "timestamp,check_num,pod_name,status,restarts,cpu,memory,node_cpu,node_memory,oom_events" > "$csv"

  local target_node="$R8I_NODE"
  local runtime="kata-qemu"
  local pod_count=16

  # Create 16 instances with 400m CPU request (total 6.4 CPU fits in 7.9 allocatable)
  # But 1 CPU limit each = 16 CPU potential = 200% oversell on 8 vCPU node
  log "Creating $pod_count kata-qemu instances on r8i node (400m req / 1 CPU lim)..."
  for i in $(seq 1 $pod_count); do
    local name="bench-t5-$(printf '%02d' $i)"
    local ns="bench-t5-$(printf '%02d' $i)"
    kubectl create namespace "$ns" >/dev/null 2>&1 || true
    local yaml
    yaml=$(gen_yaml "$name" "$ns" "$runtime" "$target_node" "kata-oversell" "400m" "1")
    echo "$yaml" | kubectl apply -f - >/dev/null 2>&1 &
    if (( i % 5 == 0 )); then
      wait
    fi
  done
  wait

  log "Waiting for pods to start..."
  sleep 120

  # Verify all pods
  log "Checking pod status..."
  for i in $(seq 1 $pod_count); do
    local name="bench-t5-$(printf '%02d' $i)"
    local ns="bench-t5-$(printf '%02d' $i)"
    local pod_name="${name}-0"
    local phase
    phase=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    local kernel
    kernel=$(kubectl exec "$pod_name" -n "$ns" -c openclaw -- uname -r 2>/dev/null || echo "N/A")
    log "Pod $pod_name: $phase (kernel: $kernel)"
  done

  # Monitor for 2 hours, every 5 minutes = 24 checks
  local total_checks=24
  local interval=300  # 5 minutes

  for check in $(seq 1 $total_checks); do
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    log "--- Monitoring check $check/$total_checks ($ts) ---"

    # Node-level metrics
    local node_cpu node_mem
    local node_top
    node_top=$(kubectl top node "$target_node" --no-headers 2>/dev/null || echo "N/A N/A N/A N/A N/A")
    node_cpu=$(echo "$node_top" | awk '{print $2}')
    node_mem=$(echo "$node_top" | awk '{print $4}')
    log "Node: CPU=$node_cpu MEM=$node_mem"

    # OOM events
    local oom_count
    oom_count=$(kubectl get events -A --field-selector=reason=OOMKilling --no-headers 2>/dev/null | wc -l || echo "0")

    # Per-pod metrics
    for i in $(seq 1 $pod_count); do
      local name="bench-t5-$(printf '%02d' $i)"
      local ns="bench-t5-$(printf '%02d' $i)"
      local pod_name="${name}-0"

      local status restarts cpu mem
      status=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
      restarts=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
      local pod_top
      pod_top=$(kubectl top pod "$pod_name" -n "$ns" --no-headers 2>/dev/null || echo "N/A N/A N/A")
      cpu=$(echo "$pod_top" | awk '{print $2}')
      mem=$(echo "$pod_top" | awk '{print $3}')

      echo "$ts,$check,$pod_name,$status,$restarts,$cpu,$mem,$node_cpu,$node_mem,$oom_count" >> "$csv"
    done

    # Gateway liveness check on first and last pod
    for idx in 1 $pod_count; do
      local name="bench-t5-$(printf '%02d' $idx)"
      local ns="bench-t5-$(printf '%02d' $idx)"
      local pod_name="${name}-0"
      local gw
      gw=$(kubectl exec "$pod_name" -n "$ns" -c openclaw -- curl -s -o /dev/null -w '%{http_code}' "http://localhost:18789/" 2>/dev/null || echo "FAIL")
      log "Gateway $pod_name: $gw"
    done

    if [[ $check -lt $total_checks ]]; then
      log "Sleeping ${interval}s until next check..."
      sleep $interval
    fi
  done

  # Cleanup
  log "Test 5 monitoring complete. Cleaning up..."
  for i in $(seq 1 $pod_count); do
    local ns="bench-t5-$(printf '%02d' $i)"
    cleanup_ns "$ns" &
  done
  wait

  log "Test 5 complete. Results: $csv"
}

# ============================================================
# MAIN
# ============================================================
main() {
  log "=== OpenClaw Kata Benchmark v2 ==="
  log "Operator: v0.22.2 | Cluster: test-s4 | EKS 1.34"

  case "${1:-all}" in
    test1) run_test1 ;;
    test2) run_test2 ;;
    test3) run_test3 ;;
    test4) run_test4 ;;
    test5) run_test5 ;;
    all)
      run_test1
      run_test2
      run_test3
      run_test4
      run_test5
      ;;
    *)
      echo "Usage: $0 {test1|test2|test3|test4|test5|all}"
      exit 1
      ;;
  esac

  log "=== All tests complete ==="
}

main "$@"
