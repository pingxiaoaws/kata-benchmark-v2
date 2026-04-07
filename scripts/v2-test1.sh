#!/bin/bash
# Test 1: Single Pod Cold Boot Time (completed - results in results/v2-test1-boot-time.csv)
# 3 runtimes (runc, kata-qemu, kata-clh) x 5 iterations each
# Uses emptyDir (no PVC) to exclude EBS latency
set -euo pipefail
source "$(dirname "$0")/v2-lib.sh"
mkdir -p "$RESULTS_DIR"
CSV="$RESULTS_DIR/v2-test1-boot-time.csv"
echo "test,runtime,iteration,boot_time_ms,status,node,timestamp" > "$CSV"
NODE="$PRIMARY_NODE"
TOL="kata-benchmark"
for runtime in runc kata-qemu kata-clh; do
  for iter in $(seq 1 5); do
    ns="v2-t1-${runtime}-${iter}"
    name="t1-${runtime}-${iter}"
    log "Test1: $runtime iteration $iter"
    start_ms=$(create_instance "$name" "$ns" "$runtime" "$TOL" "$NODE" "false")
    end_ms=$(wait_instance_ready "$name" "$ns" 300) || true
    if [[ "$end_ms" == "TIMEOUT" ]]; then
      boot_ms="NA"; status="timeout"
    else
      boot_ms=$((end_ms - start_ms)); status="ok"
    fi
    actual_node=$(get_pod_node "$ns" "$name")
    echo "test1,$runtime,$iter,$boot_ms,$status,$actual_node,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV"
    log "Test1: $runtime #$iter => ${boot_ms}ms ($status)"
    cleanup_ns "$ns"
    wait_ns_gone "$ns" 120
    sleep 3
  done
done
log "Test 1 complete."
cat "$CSV"
