#!/bin/bash
# Test 2: Node Saturated Boot Time
# Fill a single m8i.4xlarge (16 vCPU) with pods, then boot one more
# 3 runtimes x 3 iterations each
set -euo pipefail

source "$(dirname "$0")/v2-lib.sh"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/v2-test2-saturated-boot-time.csv"
echo "test,runtime,iteration,boot_time_ms,status,saturation_pods,node,timestamp" > "$CSV"

NODE="$PRIMARY_NODE"
TOL="kata-benchmark"
# m8i.4xlarge: 16 vCPU. System pods use ~1.5 CPU. Allocatable ~14.5 CPU.
# 800m per pod => 18 pods max. Saturate with 16 to leave room for 1 extra + overhead.
SAT_COUNT=16

for runtime in runc kata-qemu kata-clh; do
  log "Test2: Saturating node with $SAT_COUNT pods ($runtime)"

  # Create saturation pods (each in own namespace)
  for i in $(seq 1 $SAT_COUNT); do
    ns="v2-t2s-${runtime}-${i}"
    name="t2s-${runtime}-${i}"
    create_instance "$name" "$ns" "$runtime" "$TOL" "$NODE" "false" >/dev/null
  done

  # Wait for saturation pods to be ready
  log "Test2: Waiting for saturation pods..."
  sleep 30
  for attempt in $(seq 1 30); do
    ready=0
    for i in $(seq 1 $SAT_COUNT); do
      ns="v2-t2s-${runtime}-${i}"
      name="t2s-${runtime}-${i}"
      rc=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      [[ "$rc" == "True" ]] && ready=$((ready + 1))
    done
    log "Test2: $ready/$SAT_COUNT saturation pods ready (attempt $attempt)"
    [[ $ready -ge $SAT_COUNT ]] && break
    sleep 15
  done

  # Now test extra pod
  for iter in $(seq 1 3); do
    ns="v2-t2x-${runtime}-${iter}"
    name="t2x-${runtime}-${iter}"
    log "Test2: $runtime extra pod #$iter on saturated node"

    start_ms=$(create_instance "$name" "$ns" "$runtime" "$TOL" "$NODE" "false")
    end_ms=$(wait_instance_ready "$name" "$ns" 300) || true

    if [[ "$end_ms" == "TIMEOUT" ]]; then
      boot_ms="NA"
      status="timeout"
    else
      boot_ms=$((end_ms - start_ms))
      status="ok"
    fi

    log "Test2: $runtime #$iter => ${boot_ms}ms ($status)"
    echo "test2,$runtime,$iter,$boot_ms,$status,$SAT_COUNT,$NODE,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CSV"

    cleanup_ns "$ns"
    wait_ns_gone "$ns" 60
    sleep 3
  done

  # Cleanup saturation pods
  log "Test2: Cleaning up saturation pods for $runtime"
  for i in $(seq 1 $SAT_COUNT); do
    cleanup_ns "v2-t2s-${runtime}-${i}"
  done
  # Wait for all to be gone
  for i in $(seq 1 $SAT_COUNT); do
    wait_ns_gone "v2-t2s-${runtime}-${i}" 120
  done
  sleep 15
done

log "Test 2 complete. Results:"
cat "$CSV"
