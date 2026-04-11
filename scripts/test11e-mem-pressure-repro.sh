#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/v2-lib.sh"

NODE="ip-172-31-17-237.us-west-2.compute.internal"
TAINT_KEY="kata-oversell"
RESULTS="/home/ec2-user/kata-benchmark-v2/results"
CSV="$RESULTS/v2-test11e-mem-pressure.csv"
LOG="$RESULTS/v2-test11e-mem-pressure-stdout.log"
MAX_PODS=10
GUEST_MEM=4096   # 4 GiB guest RAM per VM
STRESS_MEM="2g"  # stress-ng will dirty 2 GiB inside guest → QEMU RSS ~2.5 GiB

log() { echo "[$(date '+%H:%M:%S')] $*"; }
exec > >(tee -a "$LOG") 2>&1

gen_pod() {
  local name="$1" ns="$2"
  # Pod with stress-ng --vm to actively consume guest memory
  # This forces QEMU RSS to grow on the host
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: mem-pressure-test
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
  - name: stress
    image: polinux/stress-ng:latest
    command: ["stress-ng", "--vm", "2", "--vm-bytes", "${STRESS_MEM}", "--vm-keep", "--timeout", "0"]
    resources:
      requests:
        cpu: "500m"
        memory: "3Gi"
      limits:
        cpu: "2000m"
        memory: "3584Mi"
  - name: sleep
    image: busybox:1.36
    command: ["sleep", "infinity"]
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
}

snapshot() {
  local phase="$1" target="$2"
  local running pending failed not_ready restarts
  local node_cpu mem_avail mem_total shm_used qemu_count qemu_cpu qemu_mem ts

  running=$(kubectl get pods -A -l app=mem-pressure-test --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  pending=$(kubectl get pods -A -l app=mem-pressure-test --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
  failed=$(kubectl get pods -A -l app=mem-pressure-test --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
  not_ready=$(kubectl get pods -A -l app=mem-pressure-test --no-headers 2>/dev/null | awk '$2 !~ /2\/2/' | wc -l)
  restarts=$(kubectl get pods -A -l app=mem-pressure-test --no-headers 2>/dev/null | awk '{sum += $4} END {print sum+0}')

  node_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    read -r _ _ _ _ idle rest < /proc/stat; sleep 1; read -r _ _ _ _ idle2 rest2 < /proc/stat
    total=$((idle + $(echo $rest | tr " " "+")))
    total2=$((idle2 + $(echo $rest2 | tr " " "+")))
    printf "%.1f" $(echo "100 * (1 - ($idle2 - $idle) / ($total2 - $total))" | bc -l)
  ' 2>/dev/null || echo "0")

  mem_avail=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  mem_total=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

  shm_used=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- df /dev/shm --output=used -B1M 2>/dev/null | tail -1 | tr -d ' ' || echo "0")

  qemu_count=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- pgrep -c qemu-system 2>/dev/null || echo "0")
  qemu_cpu=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo %cpu,comm --no-headers | grep qemu-system | awk "{s+=\$1} END {printf \"%.1f\", s+0}"
  ' 2>/dev/null || echo "0")
  # Total QEMU RSS in MiB
  qemu_mem=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo rss,comm --no-headers | grep qemu-system | awk "{s+=\$1} END {printf \"%.0f\", s/1024}"
  ' 2>/dev/null || echo "0")

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "  phase=$phase target=$target running=$running pending=$pending failed=$failed not_ready=$not_ready restarts=$restarts"
  log "  node_cpu=${node_cpu}% mem_total=${mem_total}MiB mem_avail=${mem_avail}MiB shm_used=${shm_used}MiB"
  log "  qemu_count=$qemu_count qemu_cpu=${qemu_cpu}% qemu_total_rss=${qemu_mem}MiB"
  echo "$phase,$target,$running,$pending,$failed,$not_ready,$restarts,$node_cpu,$mem_total,$mem_avail,$shm_used,$qemu_count,$qemu_cpu,$qemu_mem,$ts" >> "$CSV"
}

show_top() {
  log "  === Host top (QEMU + virtiofsd) ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- sh -c '
    ps -eo pid,user,pri,ni,vsz,rss,shr,%cpu,%mem,comm --sort=-%mem --no-headers | \
    grep -E "qemu-system|virtiofsd" | \
    while read pid user pri ni vsz rss shr cpu mem comm; do
      printf "  %7s %-8s %3s %3s %10s %8s %8s %6s %5s %s\n" \
        "$pid" "$user" "$pri" "$ni" \
        "$(echo "$vsz" | awk "{printf \"%.1fG\", \$1/1048576}")" \
        "$(echo "$rss" | awk "{printf \"%.1fG\", \$1/1048576}")" \
        "$(echo "$shr" | awk "{printf \"%.1fG\", \$1/1048576}")" \
        "$cpu" "$mem" "$comm"
    done
  ' 2>/dev/null || true
  log "  ================================="
}

cleanup() {
  log ""
  log "=== Cleanup (trap) ==="
  log "Cleaning up pods..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11em-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  # Restore kata config
  log "Restoring default_memory to 2048..."
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    sed -i 's/^default_memory = .*/default_memory = 2048/' \
    /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml 2>/dev/null || true
  log "Waiting for namespace cleanup..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl wait --for=delete ns/"t11em-$i" --timeout=120s 2>/dev/null || true
  done
  log "Done."
}
trap cleanup EXIT

main() {
  log "=== Test 11e: Memory Pressure Reproduction ==="
  log "Node: $NODE (m8i.2xlarge, 8 vCPU, 32 GiB)"
  log "Plan: default_memory=${GUEST_MEM}MiB, stress-ng --vm ${STRESS_MEM} per VM"
  log "Expected: QEMU RSS ~2.5-3 GiB each, OOM at pod 7-8"
  log ""

  # Clean leftovers
  log "Cleaning up leftover namespaces..."
  for i in $(seq 1 $MAX_PODS); do
    kubectl delete ns "t11em-$i" --ignore-not-found --wait=false 2>/dev/null || true
  done
  sleep 5

  # Set guest memory to 4 GiB
  log "Setting default_memory=$GUEST_MEM..."
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    sed -i "s/^default_memory = .*/default_memory = $GUEST_MEM/" \
    /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- \
    grep "default_memory" /opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml
  log ""

  echo "phase,target_pods,running,pending,failed,not_ready,total_restarts,node_cpu_pct,mem_total_MiB,mem_available_MiB,shm_used_MiB,qemu_count,qemu_total_cpu_pct,qemu_total_rss_MiB,timestamp" > "$CSV"

  # Baseline
  log "=== Phase 0: Baseline ==="
  sleep 3
  snapshot "baseline" 0
  log ""

  # Deploy pods one by one
  for i in $(seq 1 $MAX_PODS); do
    log "=== Phase $i: Deploying pod stress-$i ($i / $MAX_PODS) ==="
    local ns="t11em-$i"
    kubectl create ns "$ns" 2>/dev/null || true

    gen_pod "stress-$i" "$ns" | kubectl apply -f - 2>/dev/null

    log "  Waiting up to 180s for pod Ready..."
    if kubectl wait --for=condition=Ready "pod/stress-$i" -n "$ns" --timeout=180s 2>/dev/null; then
      log "  ✅ Pod stress-$i is Ready"
    else
      log "  ❌ Pod stress-$i FAILED to become Ready within 180s"
      log "  Pod status:"
      kubectl get pod "stress-$i" -n "$ns" -o wide 2>/dev/null || true
      kubectl describe pod "stress-$i" -n "$ns" 2>/dev/null | grep -A5 "Events\|Warning\|Error\|OOM\|Evict" || true
      log "  Recent dmesg:"
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- dmesg --time-format iso 2>/dev/null | tail -30 | grep -iE "oom|kill|memory|out.of|invoke|cgroup" || echo "  (none)"
    fi

    # Wait for stress-ng to warm up and dirty memory
    log "  Waiting 20s for memory to fill..."
    sleep 20

    snapshot "deployed-$i" "$i"
    show_top
    log ""

    # Check for failure conditions
    local crash_pods
    crash_pods=$(kubectl get pods -A -l app=mem-pressure-test --no-headers 2>/dev/null | awk '$3 ~ /Error|CrashLoop|OOM|Evicted/' | wc -l)
    local evicted
    evicted=$(kubectl get pods -A -l app=mem-pressure-test --no-headers 2>/dev/null | awk '$3 ~ /Evicted/' | wc -l)

    if [[ "$crash_pods" -gt 0 ]] || [[ "$evicted" -gt 0 ]]; then
      log "=== 🔴 Failure detected (crash=$crash_pods, evicted=$evicted) ==="
      log "Pod statuses:"
      kubectl get pods -A -l app=mem-pressure-test -o wide 2>/dev/null || true
      log ""
      log "dmesg tail:"
      kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- dmesg --time-format iso 2>/dev/null | tail -50 || true
      log ""
      # A few more samples
      for s in 1 2 3; do
        sleep 15
        snapshot "post-fail-$s" "$i"
        show_top
      done
      break
    fi

    # Check if mem_avail is getting critically low
    local avail
    avail=$(kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "99999")
    if [[ "$avail" -lt 1024 ]]; then
      log "=== ⚠️  MemAvailable < 1 GiB ($avail MiB) — approaching OOM ==="
      show_top
      # Deploy one more to trigger OOM
      continue
    fi
  done

  log ""
  log "=== Final Status ==="
  kubectl get pods -A -l app=mem-pressure-test -o wide 2>/dev/null || true
  log ""
  log "=== Host Memory ==="
  kubectl exec hostmon -- nsenter -t 1 -m -u -i -n -p -- free -h 2>/dev/null || true
  log ""
  log "=== CSV ==="
  cat "$CSV"
  log ""
  log "Test 11e (memory pressure) complete."
}

main "$@"
