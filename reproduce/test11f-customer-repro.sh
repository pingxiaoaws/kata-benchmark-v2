#!/usr/bin/env bash
set -euo pipefail
#
# Test 11f: Customer Environment Reproduction
# Goal: Reproduce kata-agent timeout crash under CPU overcommit on m8i.2xlarge (8 vCPU, 32 GiB)
#
# Customer scenario:
#   - Kata QEMU with default_vcpus=5, default_memory=2048
#   - Each pod: 4 containers (gateway + config-watcher + envoy + wazuh)
#     Container totals: 450m CPU request, 2Gi memory request
#   - Kata overhead: 500m CPU, 640Mi memory
#   - Per pod scheduling: 950m CPU, ~2.6Gi memory
#   - 7 pods on m8i.2xlarge (8 vCPU) = 6650m CPU requests (90%)
#   - Problem 1: 7th pod probe failure during startup
#   - Problem 2: Running pods restart with "Dead agent" / exit 255
#
# Reproduction approach:
#   - Deploy 7 kata-qemu pods matching customer spec on our m8i.2xlarge test node
#   - Each pod has 4 containers with matching resource profiles
#   - Monitor for agent timeouts, restarts, and exit 255
#   - Capture host top, /dev/shm, MemAvailable, QEMU process data
#
source "$(dirname "$0")/v2-lib.sh"

NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"
RESULTS="/home/ec2-user/kata-benchmark-v2/results"
CSV="$RESULTS/v2-test11f-customer-repro.csv"
LOG="$RESULTS/v2-test11f-customer-repro-stdout.log"
MAX_PODS=8

log() { echo "[$(date '+%H:%M:%S')] $*"; }
exec > >(tee -a "$LOG") 2>&1

# Generate a pod matching the customer's 4-container layout
gen_customer_pod() {
  local name="$1" ns="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: customer-repro
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    workload-type: kata
    kubernetes.io/hostname: ${NODE}
  tolerations:
  - key: ${TAINT_KEY}
    operator: Equal
    value: "true"
    effect: NoSchedule
  overhead:
    memory: "640Mi"
    cpu: "500m"
  containers:
  # Gateway - 150m/1Gi request, simulated with nginx + memory allocation
  - name: gateway
    image: nginx:1.27
    resources:
      requests:
        cpu: "150m"
        memory: "1Gi"
      limits:
        cpu: "1500m"
        memory: "2Gi"
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 10
      timeoutSeconds: 5
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 5
  # Config-watcher - 100m/256Mi request
  - name: config-watcher
    image: busybox:1.36
    command: ["sh", "-c", "while true; do sleep 5; cat /proc/loadavg > /dev/null; done"]
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
  # Envoy - 100m/256Mi request, simulated with busy loop
  - name: envoy
    image: busybox:1.36
    command: ["sh", "-c", "while true; do dd if=/dev/zero of=/dev/null bs=1k count=100 2>/dev/null; sleep 0.1; done"]
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
  # Wazuh (security agent) - 100m/512Mi request, simulated with periodic work
  - name: wazuh
    image: busybox:1.36
    command: ["sh", "-c", "while true; do find / -maxdepth 3 -type f 2>/dev/null | wc -l > /dev/null; sleep 2; done"]
    resources:
      requests:
        cpu: "100m"
        memory: "512Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
EOF
}

snapshot() {
  local phase="$1" target="$2"
  local running pending failed not_ready restarts
  local node_cpu mem_avail mem_total shm_used
  local qemu_count qemu_cpu qemu_mem vfs_count vfs_cpu
  local smp ts

  running=$(kubectl get pods -A -l app=customer-repro --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  pending=$(kubectl get pods -A -l app=customer-repro --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
  failed=$(kubectl get pods -A -l app=customer-repro --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
  not_ready=$(kubectl get pods -A -l app=customer-repro --no-headers 2>/dev/null | awk '$2 !~ /4\/4/' | wc -l)
  restarts=$(kubectl get pods -A -l app=customer-repro --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')

  node_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    read -r _ u1 n1 s1 i1 w1 q1 sq1 rest < /proc/stat
    sleep 2
    read -r _ u2 n2 s2 i2 w2 q2 sq2 rest < /proc/stat
    total1=$((u1+n1+s1+i1+w1+q1+sq1))
    total2=$((u2+n2+s2+i2+w2+q2+sq2))
    idle_d=$((i2-i1))
    total_d=$((total2-total1))
    if [ "$total_d" -gt 0 ]; then
      printf "%.1f" $(echo "100*(1-$idle_d/$total_d)" | bc -l)
    else
      echo "0.0"
    fi
  ' 2>/dev/null || echo "0")

  mem_avail=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  mem_total=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  shm_used=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df /dev/shm --output=used -B1M 2>/dev/null | tail -1 | tr -d ' ' || echo "0")

  qemu_count=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'pgrep -c qemu-system 2>/dev/null || echo 0')
  qemu_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo %cpu,comm --no-headers | grep qemu-system | awk "{s+=\$1} END {printf \"%.1f\", s+0}"
  ' 2>/dev/null || echo "0")
  qemu_mem=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo rss,comm --no-headers | grep qemu-system | awk "{s+=\$1} END {printf \"%.0f\", s/1024}"
  ' 2>/dev/null || echo "0")
  vfs_count=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c 'pgrep -c virtiofsd 2>/dev/null || echo 0')
  vfs_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo %cpu,comm --no-headers | grep virtiofsd | awk "{s+=\$1} END {printf \"%.1f\", s+0}"
  ' 2>/dev/null || echo "0")

  smp=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c \
    "ps aux | grep qemu-system | grep -v grep | head -1 | grep -oP '\-smp \K[^ ]+'" 2>/dev/null || echo "N/A")

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "  phase=$phase target=$target running=$running pending=$pending failed=$failed not_ready=$not_ready restarts=$restarts"
  log "  node_cpu=${node_cpu}% mem_total=${mem_total}MiB mem_avail=${mem_avail}MiB shm=${shm_used}MiB"
  log "  qemu=$qemu_count(${qemu_cpu}% CPU, ${qemu_mem}MiB RSS) vfs=$vfs_count(${vfs_cpu}%) smp=$smp"
  echo "$phase,$target,$running,$pending,$failed,$not_ready,$restarts,$node_cpu,$mem_total,$mem_avail,$shm_used,$qemu_count,$qemu_cpu,$qemu_mem,$vfs_count,$vfs_cpu,$smp,$ts" >> "$CSV"
}

show_host_top() {
  log "  === Host top (QEMU + virtiofsd) ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    ps -eo pid,user,%cpu,%mem,rss,vsz,comm --sort=-%cpu --no-headers 2>/dev/null | \
    grep -E "qemu-system|virtiofsd" | head -20 | \
    while read pid user cpu mem rss vsz comm; do
      rss_m=$((rss / 1024))
      vsz_g=$(echo "scale=1; $vsz/1048576" | bc 2>/dev/null || echo "?")
      log "    PID=$pid CPU=${cpu}% MEM=${mem}% RSS=${rss_m}MiB VIRT=${vsz_g}GiB $comm"
    done
  log "  ================================="
}

show_pod_status() {
  log "  === Pod Status ==="
  kubectl get pods -A -l app=customer-repro -o wide --no-headers 2>/dev/null | while read line; do
    log "    $line"
  done
  log "  ==================="
}

check_agent_errors() {
  # Check for agent timeout errors in containerd logs (last 60s)
  local errors
  errors=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    journalctl -u containerd --since "60 seconds ago" --no-pager 2>/dev/null | \
    grep -ciE "dead agent|timed out|CheckRequest|exit.status.*255|sandbox stopped" || echo "0")
  echo "$errors"
}

cleanup() {
  log ""
  log "=== Cleanup (trap) ==="
  log "Cleaning up..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11f-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  log "Waiting for namespace cleanup..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl wait --for=delete ns/"t11f-$i" --timeout=120s 2>/dev/null || true
  done
  log "Done."
}
trap cleanup EXIT

main() {
  log "============================================================="
  log "  Test 11f: Customer Environment Reproduction"
  log "============================================================="
  log ""
  log "Node: $NODE (m8i.2xlarge, 8 vCPU, 32 GiB)"
  log "Kata: default_vcpus=5, default_memory=2048"
  log ""
  log "Pod spec (matching customer):"
  log "  gateway:        150m/1Gi  request, 1500m/2Gi  limit"
  log "  config-watcher: 100m/256Mi request, 500m/512Mi limit"
  log "  envoy:          100m/256Mi request, 500m/512Mi limit"
  log "  wazuh:          100m/512Mi request, 500m/1Gi  limit"
  log "  Container total: 450m CPU / 2Gi memory requests"
  log "  Kata overhead:   500m CPU / 640Mi memory"
  log "  Pod scheduling:  950m CPU / ~2.6Gi memory"
  log ""
  log "Target: deploy 7 pods → 6650m/8000m = 83% CPU requests"
  log "  CPU limits: 3000m × 7 = 21000m → 262% overcommit"
  log ""
  log "Expected: agent timeout → Dead agent → exit 255 → restarts"
  log "============================================================="
  log ""

  # Clean any leftovers
  log "Cleaning up leftover namespaces..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11f-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  sleep 5

  # Verify kata config
  log "Kata config verification:"
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    grep -E "^default_vcpus|^default_memory|^default_maxvcpus" \
    /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml 2>/dev/null
  log ""

  echo "phase,target_pods,running,pending,failed,not_ready,total_restarts,node_cpu_pct,mem_total_MiB,mem_available_MiB,shm_used_MiB,qemu_count,qemu_total_cpu_pct,qemu_total_rss_MiB,vfs_count,vfs_total_cpu_pct,smp_value,timestamp" > "$CSV"

  # === Phase 0: Baseline ===
  log "=== Phase 0: Baseline ==="
  sleep 3
  snapshot "baseline" 0
  log ""

  # === Deploy pods one by one ===
  for i in $(seq 1 $MAX_PODS); do
    log "=== Phase $i: Deploying sandbox-$i ($i / $MAX_PODS) ==="
    local ns="t11f-$i"
    kubectl create ns "$ns" 2>/dev/null || true

    gen_customer_pod "sandbox-$i" "$ns" | kubectl apply -f - 2>/dev/null

    log "  Waiting up to 180s for pod Ready (all 4 containers)..."
    if kubectl wait --for=condition=Ready "pod/sandbox-$i" -n "$ns" --timeout=180s 2>/dev/null; then
      log "  ✅ Pod sandbox-$i is Ready (4/4 containers)"
    else
      log "  ❌ Pod sandbox-$i FAILED to become Ready within 180s"
      log "  Pod status:"
      kubectl get pod "sandbox-$i" -n "$ns" -o wide 2>/dev/null || true
      log "  Events:"
      kubectl describe pod "sandbox-$i" -n "$ns" 2>/dev/null | tail -25
    fi

    # Wait for containers to stabilize
    log "  Waiting 30s for workload stabilization..."
    sleep 30

    snapshot "deployed-$i" "$i"
    show_host_top
    show_pod_status
    log ""
  done

  # === Steady-state monitoring (10 minutes) ===
  log "=== Steady-state monitoring (10 min, sample every 60s) ==="
  local start_restarts
  start_restarts=$(kubectl get pods -A -l app=customer-repro --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')
  log "  Starting restarts: $start_restarts"

  for sample in $(seq 1 10); do
    sleep 60
    snapshot "steady-$sample" "$MAX_PODS"

    local cur_restarts
    cur_restarts=$(kubectl get pods -A -l app=customer-repro --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')
    local new_restarts=$((cur_restarts - start_restarts))

    # Check for agent errors
    local agent_errors
    agent_errors=$(check_agent_errors)

    log "  [steady-$sample] new_restarts=$new_restarts agent_errors_last_60s=$agent_errors"

    if [[ "$new_restarts" -gt 0 ]]; then
      log "  🔴 Restarts detected! Capturing diagnostics..."
      show_host_top
      show_pod_status

      # Capture containerd logs for agent timeout evidence
      log "  === containerd logs (last 120s, filtered) ==="
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
        journalctl -u containerd --since "120 seconds ago" --no-pager 2>/dev/null | \
        grep -iE "dead agent|timed out|CheckRequest|exit.status.*255|sandbox stopped|ping agent" | \
        tail -30 | while read line; do
          log "    $line"
        done
      log "  ============================================="
    fi

    if [[ "$agent_errors" -gt 0 ]]; then
      log "  ⚠️  Agent errors detected in containerd logs"
    fi
  done

  # === Final summary ===
  log ""
  log "============================================================="
  log "  FINAL SUMMARY"
  log "============================================================="
  log ""

  local final_restarts
  final_restarts=$(kubectl get pods -A -l app=customer-repro --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')
  log "Total restarts: $final_restarts (started at $start_restarts, delta=$((final_restarts - start_restarts)))"
  log ""

  show_pod_status
  show_host_top

  log ""
  log "=== Host Memory ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h 2>/dev/null
  log ""
  log "=== /dev/shm ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df -h /dev/shm 2>/dev/null
  log ""
  log "=== dmesg (OOM/memory) ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- dmesg --time-format iso 2>/dev/null | \
    grep -iE "oom|kill|out.of.memory" | tail -10 || log "  (none)"
  log ""

  log "=== CSV ==="
  cat "$CSV"
  log ""
  log "Test 11f complete."
}

main "$@"
