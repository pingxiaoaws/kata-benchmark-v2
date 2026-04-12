#!/usr/bin/env bash
set -euo pipefail
#
# Test 11h: Reproduce Memory OOM Scenarios
#
# Demonstrates three types of memory-related pod failures in Kata:
#   Scenario A: Guest-internal OOM (container exceeds memory limit) → exit 137
#   Scenario B: Guest memory pressure (probe timeout, not OOM) → exit 0
#   Scenario C: Host-level OOM (QEMU killed by host kernel) → Dead agent
#
# Usage: bash test11h-memory-oom-repro.sh [scenario_a|scenario_b|scenario_c|all]
#

NODE="ip-172-31-17-237.us-west-2.compute.internal"
SCENARIO="${1:-all}"
NS_PREFIX="t11h"

cleanup() {
  echo ""
  echo "=== Cleanup ==="
  for ns in $(kubectl get ns -o name 2>/dev/null | grep "${NS_PREFIX}" | sed 's|namespace/||'); do
    kubectl delete ns "$ns" --force --grace-period=0 2>/dev/null &
  done
  wait
  echo "Cleanup done."
}

wait_and_observe() {
  local ns="$1" pod="$2" duration="${3:-60}"
  echo "  Observing for ${duration}s..."
  for i in $(seq 1 $((duration / 10))); do
    sleep 10
    local status
    status=$(kubectl get pod "$pod" -n "$ns" -o wide --no-headers 2>/dev/null || echo "NOT FOUND")
    echo "  [+${i}0s] $status"
  done
}

#######################################################################
# Scenario A: Guest-internal OOM (container exceeds memory limit)
#
# A container tries to allocate more memory than its cgroup limit.
# Guest kernel's OOM killer kills the process → exit code 137.
# Only the offending container restarts; other containers unaffected.
#######################################################################
scenario_a() {
  echo "============================================================="
  echo "  Scenario A: Guest-internal OOM (exit 137)"
  echo "  Container allocates beyond its memory limit"
  echo "============================================================="

  local ns="${NS_PREFIX}-oom"
  kubectl create ns "$ns" 2>/dev/null || true

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-victim
  namespace: ${ns}
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
    workload-type: kata
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
  - key: kata-oversell
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  # This container will be OOM killed: limit=256Mi but tries to allocate 512Mi
  - name: memory-hog
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo "Starting memory allocation..."
      echo "Memory limit: 256Mi, will try to allocate 512Mi"
      sleep 5
      # Write 512 MiB to /dev/shm (tmpfs = guest RAM)
      # This exceeds the 256Mi container memory limit → OOM kill
      dd if=/dev/urandom of=/dev/shm/overcommit bs=1M count=512 2>&1
      echo "If you see this, OOM did not trigger (unexpected)"
      sleep infinity
    resources:
      requests: { cpu: "50m", memory: "128Mi" }
      limits:   { cpu: "200m", memory: "256Mi" }
  # This container is fine, should NOT be affected
  - name: healthy-sidecar
    image: busybox:1.36
    command: ["/bin/sh", "-c", "while true; do echo alive; sleep 10; done"]
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits:   { cpu: "100m", memory: "128Mi" }
EOF

  echo "  Pod created. Waiting for it to start..."
  kubectl wait --for=condition=Ready "pod/oom-victim" -n "$ns" --timeout=120s 2>/dev/null || true
  sleep 5

  wait_and_observe "$ns" "oom-victim" 60

  echo ""
  echo "=== Pod Status ==="
  kubectl get pod oom-victim -n "$ns" -o wide 2>/dev/null

  echo ""
  echo "=== Container Details ==="
  kubectl get pod oom-victim -n "$ns" -o jsonpath='{range .status.containerStatuses[*]}
Container: {.name}
  State: {.state}
  Last State: {.lastState}
  Restart Count: {.restartCount}
{end}' 2>/dev/null

  echo ""
  echo "=== kubectl describe (Events) ==="
  kubectl describe pod oom-victim -n "$ns" 2>/dev/null | grep -A 30 "Events:"

  echo ""
  echo "Expected: memory-hog → OOMKilled, exit 137, restartCount > 0"
  echo "Expected: healthy-sidecar → Running, restartCount = 0"
}

#######################################################################
# Scenario B: Guest memory pressure → probe timeout (exit 0)
#
# Multiple sidecars allocate large /dev/shm blocks simultaneously.
# Guest memory allocation storm slows nginx → liveness probe timeout.
# Kubelet kills nginx with SIGTERM (graceful) → exit 0, Reason=Completed.
# NOT OOM kill. Only affects the probed container.
#######################################################################
scenario_b() {
  echo "============================================================="
  echo "  Scenario B: Memory pressure → liveness probe timeout (exit 0)"
  echo "  Sidecars fill /dev/shm, nginx can't respond in time"
  echo "============================================================="

  local ns="${NS_PREFIX}-pressure"
  kubectl create ns "$ns" 2>/dev/null || true

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pressure-victim
  namespace: ${ns}
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
    workload-type: kata
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
  - key: kata-oversell
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  - name: gateway
    image: nginx:1.27
    resources:
      requests: { cpu: "100m", memory: "512Mi" }
      limits:   { cpu: "500m", memory: "1Gi" }
    livenessProbe:
      httpGet: { path: /, port: 80 }
      initialDelaySeconds: 5
      periodSeconds: 5
      timeoutSeconds: 1
      failureThreshold: 3
  # Three sidecars each allocate 800 MiB simultaneously → 2.4 GiB memory storm
  - name: sidecar-1
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args: ["dd if=/dev/urandom of=/dev/shm/block1 bs=1M count=800 2>/dev/null; sleep infinity"]
    resources:
      requests: { cpu: "50m", memory: "128Mi" }
      limits:   { cpu: "200m", memory: "1Gi" }
  - name: sidecar-2
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args: ["dd if=/dev/urandom of=/dev/shm/block2 bs=1M count=800 2>/dev/null; sleep infinity"]
    resources:
      requests: { cpu: "50m", memory: "128Mi" }
      limits:   { cpu: "200m", memory: "1Gi" }
  - name: sidecar-3
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args: ["dd if=/dev/urandom of=/dev/shm/block3 bs=1M count=800 2>/dev/null; sleep infinity"]
    resources:
      requests: { cpu: "50m", memory: "128Mi" }
      limits:   { cpu: "200m", memory: "1Gi" }
EOF

  echo "  Pod created. Watching for probe failures..."
  wait_and_observe "$ns" "pressure-victim" 90

  echo ""
  echo "=== Pod Status ==="
  kubectl get pod pressure-victim -n "$ns" -o wide 2>/dev/null

  echo ""
  echo "=== Events ==="
  kubectl describe pod pressure-victim -n "$ns" 2>/dev/null | grep -A 30 "Events:"

  echo ""
  echo "Expected: gateway restarts with Reason=Completed (exit 0), NOT OOMKilled"
  echo "Expected: sidecars stay running (restartCount = 0)"
}

#######################################################################
# Scenario C: Host-level OOM (too many VMs exhaust host memory)
#
# WARNING: This is destructive — host OOM killer will kill QEMU processes.
# Deploy many VMs to exhaust host memory → host kernel kills QEMU.
# Requires large memory allocation per VM.
# Uncomment to run (disabled by default for safety).
#######################################################################
scenario_c() {
  echo "============================================================="
  echo "  Scenario C: Host-level OOM (QEMU killed by host kernel)"
  echo "  WARNING: Destructive test, skipped by default"
  echo "============================================================="
  echo ""
  echo "  To reproduce host OOM:"
  echo "  1. Deploy enough Kata pods to exhaust host memory"
  echo "  2. Each VM allocates guest RAM via memfd → host physical memory"
  echo "  3. When host MemAvailable → 0, kernel OOM killer activates"
  echo "  4. Kills highest-RSS process = QEMU → entire VM dies"
  echo ""
  echo "  Signature in host dmesg:"
  echo '    [xxx] Out of memory: Killed process 12345 (qemu-system-x86)'
  echo '    total-vm:8752108kB, anon-rss:2457600kB, file-rss:0kB'
  echo ""
  echo "  Signature in containerd logs:"
  echo '    [WARN]  failed to ping agent: Dead agent'
  echo '    (same as CPU contention, but dmesg has OOM evidence)'
  echo ""
  echo "  Key difference from CPU contention:"
  echo "    - Usually kills ONE QEMU (highest RSS), not cascade"
  echo "    - Host dmesg clearly shows OOM killer invocation"
  echo "    - Other VMs may survive (OOM killer frees enough memory)"
  echo ""
  echo "  Skipping actual execution. Adjust MAX_VMS and run manually if needed."
}

#######################################################################
# Main
#######################################################################
echo "============================================================="
echo "  Test 11h: Memory OOM Reproduction"
echo "  Scenario: ${SCENARIO}"
echo "============================================================="
echo ""

case "$SCENARIO" in
  scenario_a|a)
    scenario_a
    ;;
  scenario_b|b)
    scenario_b
    ;;
  scenario_c|c)
    scenario_c
    ;;
  all)
    scenario_a
    echo ""
    echo "=== Cleaning up Scenario A before Scenario B ==="
    kubectl delete ns "${NS_PREFIX}-oom" --force --grace-period=0 2>/dev/null &
    sleep 30
    scenario_b
    echo ""
    scenario_c
    ;;
  cleanup)
    cleanup
    ;;
  *)
    echo "Usage: $0 [scenario_a|scenario_b|scenario_c|all|cleanup]"
    exit 1
    ;;
esac

echo ""
echo "============================================================="
echo "  Test 11h Complete"
echo "============================================================="
echo ""
echo "Summary of failure modes:"
echo "  Scenario A: OOMKilled (exit 137) — single container, guest cgroup OOM"
echo "  Scenario B: Probe timeout (exit 0) — memory pressure, not OOM"
echo "  Scenario C: Dead agent (exit 255) — host OOM kills QEMU"
