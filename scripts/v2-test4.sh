#!/bin/bash
# Test 4: runc vs Kata Runtime Comparison
# Boot time + resource usage + gateway health check
set -euo pipefail

source "$(dirname "$0")/v2-lib.sh"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/v2-test4-runtime-comparison.csv"
echo "test,runtime,boot_time_ms,status,cpu_usage,mem_usage,gateway_check,node,timestamp" > "$CSV"

NODE="$PRIMARY_NODE"
TOL="kata-benchmark"

for runtime in runc kata-qemu kata-clh; do
  ns="v2-t4-${runtime}"
  name="t4-${runtime}"
  log "Test4: Starting $runtime"

  start_ms=$(create_instance "$name" "$ns" "$runtime" "$TOL" "$NODE" "false")
  end_ms=$(wait_instance_ready "$name" "$ns" 300) || true

  if [[ "$end_ms" == "TIMEOUT" ]]; then
    boot_ms="NA"
    status="timeout"
  else
    boot_ms=$((end_ms - start_ms))
    status="ok"
  fi

  # Wait for metrics to populate
  sleep 20

  # Resource usage
  cpu_usage="NA"
  mem_usage="NA"
  top_out=$(get_pod_resources "$ns")
  if [[ "$top_out" != "unavailable" ]]; then
    cpu_usage=$(echo "$top_out" | head -1 | awk '{print $2}')
    mem_usage=$(echo "$top_out" | head -1 | awk '{print $3}')
  fi

  # Gateway check
  gw_check="NA"
  if [[ "$status" == "ok" ]]; then
    gw_check=$(check_gateway_health "$ns" "$name") || gw_check="FAIL"
  fi

  actual_node=$(get_pod_node "$ns" "$name")
  log "Test4: $runtime => ${boot_ms}ms CPU=$cpu_usage MEM=$mem_usage GW=$gw_check"
  echo "test4,$runtime,$boot_ms,$status,$cpu_usage,$mem_usage,$gw_check,$actual_node,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV"

  cleanup_ns "$ns"
  wait_ns_gone "$ns" 120
  sleep 5
done

log "Test 4 complete. Results:"
cat "$CSV"
