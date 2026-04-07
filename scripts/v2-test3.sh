#!/bin/bash
# Test 3: Multi-Node Cluster Scale Boot
# Fill 10 m8i.4xlarge nodes, then boot one more
# 3 runtimes x 3 iterations each
set -euo pipefail

source "$(dirname "$0")/v2-lib.sh"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/v2-test3-multi-node-boot-time.csv"
echo "test,runtime,iteration,boot_time_ms,status,total_saturation_pods,nodes_used,timestamp" > "$CSV"

NUM_NODES=${#ALL_M8I_NODES[@]}
PODS_PER_NODE=16

for runtime in runc kata-qemu kata-clh; do
  total_sat=$((NUM_NODES * PODS_PER_NODE))
  log "Test3: Saturating $NUM_NODES nodes with $PODS_PER_NODE pods each ($runtime) = $total_sat total"

  # Create saturation pods across all nodes
  for node_idx in $(seq 0 $((NUM_NODES - 1))); do
    node="${ALL_M8I_NODES[$node_idx]}"
    tol="kata-benchmark"
    [[ "$node" == "$UNTAINTED_NODE" ]] && tol="none"

    for i in $(seq 1 $PODS_PER_NODE); do
      ns="v2-t3s-${runtime}-n${node_idx}-${i}"
      name="t3s-${runtime}-n${node_idx}-${i}"
      create_instance "$name" "$ns" "$runtime" "$tol" "$node" "false" >/dev/null
    done
    log "Test3: Created $PODS_PER_NODE instances on node $node_idx"
  done

  # Wait for majority to be ready
  log "Test3: Waiting for saturation pods to stabilize..."
  sleep 60
  for attempt in $(seq 1 30); do
    ready=0
    for node_idx in $(seq 0 $((NUM_NODES - 1))); do
      for i in $(seq 1 $PODS_PER_NODE); do
        ns="v2-t3s-${runtime}-n${node_idx}-${i}"
        name="t3s-${runtime}-n${node_idx}-${i}"
        rc=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        [[ "$rc" == "True" ]] && ready=$((ready + 1))
      done
    done
    pct=$((ready * 100 / total_sat))
    log "Test3: $ready/$total_sat ($pct%) saturation pods ready"
    [[ $pct -ge 80 ]] && break
    sleep 20
  done

  # Test extra pod on first benchmark node
  for iter in $(seq 1 3); do
    ns="v2-t3x-${runtime}-${iter}"
    name="t3x-${runtime}-${iter}"
    log "Test3: $runtime extra pod #$iter"

    start_ms=$(create_instance "$name" "$ns" "$runtime" "kata-benchmark" "${BENCH_NODES[0]}" "false")
    end_ms=$(wait_instance_ready "$name" "$ns" 300) || true

    if [[ "$end_ms" == "TIMEOUT" ]]; then
      boot_ms="NA"
      status="timeout"
    else
      boot_ms=$((end_ms - start_ms))
      status="ok"
    fi

    log "Test3: $runtime #$iter => ${boot_ms}ms ($status)"
    echo "test3,$runtime,$iter,$boot_ms,$status,$total_sat,$NUM_NODES,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV"

    cleanup_ns "$ns"
    wait_ns_gone "$ns" 60
    sleep 3
  done

  # Cleanup all saturation
  log "Test3: Cleaning up saturation pods for $runtime"
  for node_idx in $(seq 0 $((NUM_NODES - 1))); do
    for i in $(seq 1 $PODS_PER_NODE); do
      cleanup_ns "v2-t3s-${runtime}-n${node_idx}-${i}"
    done
  done
  for node_idx in $(seq 0 $((NUM_NODES - 1))); do
    for i in $(seq 1 $PODS_PER_NODE); do
      wait_ns_gone "v2-t3s-${runtime}-n${node_idx}-${i}" 120
    done
  done
  sleep 15
done

log "Test 3 complete. Results:"
cat "$CSV"
