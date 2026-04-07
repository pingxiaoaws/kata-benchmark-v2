#!/bin/bash
# Test 5: R8i Oversell Stability
# 16 kata-qemu pods on r8i.2xlarge (8 vCPU, 64GB)
# 16 x 800m = 12.8 CPU request (60% oversell)
# Monitor 2 hours: 24 samples x 5 min interval
set -euo pipefail

source "$(dirname "$0")/v2-lib.sh"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/v2-test5-oversell-stability.csv"
echo "test,sample,elapsed_min,instance,pod_ready,restarts,phase,cpu_usage,mem_usage,gateway_alive,node_cpu,node_mem,node_cpu_pct,node_mem_pct,oom_events,timestamp" > "$CSV"

NODE="$OVERSELL_NODE"
TOL="kata-oversell"
RUNTIME="kata-qemu"
POD_COUNT=16
TOTAL_SAMPLES=24
INTERVAL=300  # 5 minutes

# Create all instances (with PVC, as specified)
log "Test5: Creating $POD_COUNT kata-qemu instances on r8i.2xlarge"
for i in $(seq 1 $POD_COUNT); do
  ns="v2-t5-${i}"
  name="t5-${i}"
  create_instance "$name" "$ns" "$RUNTIME" "$TOL" "$NODE" "true" >/dev/null
  log "Test5: Created instance $i/$POD_COUNT"
done

# Wait for instances to come up
log "Test5: Waiting 2 minutes for instances to initialize..."
sleep 120

# Check how many are ready
ready=0
for i in $(seq 1 $POD_COUNT); do
  ns="v2-t5-${i}"
  name="t5-${i}"
  rc=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$rc" == "True" ]] && ready=$((ready + 1))
done
log "Test5: $ready/$POD_COUNT instances ready before monitoring starts"

# Monitoring loop
for sample in $(seq 1 $TOTAL_SAMPLES); do
  elapsed_min=$(( (sample - 1) * 5 ))
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "Test5: Sample $sample/$TOTAL_SAMPLES (${elapsed_min}min)"

  # Node-level metrics
  node_cpu="NA"
  node_mem="NA"
  node_cpu_pct="NA"
  node_mem_pct="NA"
  node_top=$(kubectl top node "$NODE" --no-headers 2>/dev/null || echo "")
  if [[ -n "$node_top" ]]; then
    node_cpu=$(echo "$node_top" | awk '{print $2}')
    node_cpu_pct=$(echo "$node_top" | awk '{print $3}')
    node_mem=$(echo "$node_top" | awk '{print $4}')
    node_mem_pct=$(echo "$node_top" | awk '{print $5}')
  fi

  # OOM events across all t5 namespaces
  oom_total=0
  for i in $(seq 1 $POD_COUNT); do
    oom=$(count_oom_events "v2-t5-${i}")
    oom_total=$((oom_total + oom))
  done

  # Per-instance metrics
  for i in $(seq 1 $POD_COUNT); do
    ns="v2-t5-${i}"
    name="t5-${i}"

    # Pod status
    pod_ready="false"
    restarts="NA"
    phase="NA"
    cpu="NA"
    mem="NA"
    gw="skipped"

    pod_json=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o json 2>/dev/null || echo '{"items":[]}')
    pod_count=$(echo "$pod_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo 0)

    if [[ "$pod_count" -gt 0 ]]; then
      phase=$(echo "$pod_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0].get('status',{}).get('phase','Unknown'))" 2>/dev/null || echo "Unknown")
      restarts=$(echo "$pod_json" | python3 -c "
import sys,json
cs = json.load(sys.stdin)['items'][0].get('status',{}).get('containerStatuses',[])
print(sum(c.get('restartCount',0) for c in cs))" 2>/dev/null || echo "NA")
      rc=$(echo "$pod_json" | python3 -c "
import sys,json
conds = json.load(sys.stdin)['items'][0].get('status',{}).get('conditions',[])
ready = [c for c in conds if c['type']=='Ready']
print(ready[0]['status'] if ready else 'Unknown')" 2>/dev/null || echo "Unknown")
      [[ "$rc" == "True" ]] && pod_ready="true"

      # Pod resource usage
      top_out=$(kubectl top pods -n "$ns" --no-headers 2>/dev/null || echo "")
      if [[ -n "$top_out" ]]; then
        cpu=$(echo "$top_out" | head -1 | awk '{print $2}')
        mem=$(echo "$top_out" | head -1 | awk '{print $3}')
      fi
    fi

    # Gateway check every 4th sample (every 20 min)
    if (( sample % 4 == 1 )) && [[ "$pod_ready" == "true" ]]; then
      gw=$(check_gateway_health "$ns" "$name") || gw="FAIL"
    fi

    echo "test5,$sample,$elapsed_min,$name,$pod_ready,$restarts,$phase,$cpu,$mem,$gw,$node_cpu,$node_mem,$node_cpu_pct,$node_mem_pct,$oom_total,$ts" >> "$CSV"
  done

  log "Test5: Sample $sample done - node CPU=$node_cpu($node_cpu_pct) MEM=$node_mem($node_mem_pct) OOM=$oom_total"

  # Sleep until next sample
  [[ $sample -lt $TOTAL_SAMPLES ]] && sleep $INTERVAL
done

log "Test5: Monitoring complete. Cleaning up..."

# Cleanup
for i in $(seq 1 $POD_COUNT); do
  cleanup_ns "v2-t5-${i}"
done
for i in $(seq 1 $POD_COUNT); do
  wait_ns_gone "v2-t5-${i}" 120
done

log "Test 5 complete. Results written to $CSV"
