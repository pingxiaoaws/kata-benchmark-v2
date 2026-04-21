#!/usr/bin/env bash
set -euo pipefail

# === gVisor Cold Boot Benchmark ===
# Supplements Test 1 from kata-benchmark-v2
# Same OpenClaw workload, same methodology: 5 iterations on idle node
#
# NOTE: gVisor node is arm64 (m8gd.2xlarge Graviton), original Test 1 was x86 (m8i.4xlarge)
# Architecture difference means boot times are not directly comparable for CPU-sensitive metrics,
# but the cold/warm pattern and runtime overhead are still meaningful.

RESULTS_DIR="/home/ec2-user/kata-benchmark-v2/results"
mkdir -p "$RESULTS_DIR"

IMAGE_REPO="ghcr.io/openclaw/openclaw"
IMAGE_TAG="latest"

GVISOR_NODE="ip-172-31-52-209.us-west-2.compute.internal"
CSV="$RESULTS_DIR/v2-test1-gvisor-boot-time.csv"
ITERATIONS=5

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

gen_openclaw_yaml() {
  local name="$1" ns="$2" runtime_class="$3"

  local runtime_line=""
  if [[ -n "$runtime_class" && "$runtime_class" != "runc" ]]; then
    runtime_line="    runtimeClassName: $runtime_class"
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
      cpu: 800m
      memory: 2Gi
    limits:
      cpu: "1"
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
    nodeSelector:
      workload-type: gvisor
      kubernetes.io/hostname: $GVISOR_NODE
    tolerations:
      - key: gvisor
        operator: Equal
        value: "true"
        effect: NoSchedule
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

cleanup_ns() {
  local ns="$1"
  log "Cleaning up namespace $ns..."
  kubectl delete namespace "$ns" --wait=false 2>/dev/null || true
  # Wait for namespace to actually be deleted
  for attempt in $(seq 1 60); do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  log "Namespace $ns cleaned up"
}

# ============================================================
# Pre-flight checks
# ============================================================
log "=== gVisor Cold Boot Benchmark ==="
log "Node: $GVISOR_NODE"
log "Iterations: $ITERATIONS"

# Verify node is ready
if ! kubectl get node "$GVISOR_NODE" --no-headers 2>/dev/null | grep -q "Ready"; then
  log "ERROR: Node $GVISOR_NODE is not Ready"
  exit 1
fi

# Show node info
NODE_ARCH=$(kubectl get node "$GVISOR_NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')
NODE_INSTANCE=$(kubectl get node "$GVISOR_NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
NODE_KERNEL=$(kubectl get node "$GVISOR_NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}')
log "Architecture: $NODE_ARCH | Instance: $NODE_INSTANCE | Kernel: $NODE_KERNEL"

# Clean up any leftover test namespaces
for i in $(seq 1 $ITERATIONS); do
  kubectl delete namespace "bench-gv-${i}" --wait=false 2>/dev/null || true
done
sleep 5

# ============================================================
# Run cold boot test
# ============================================================
echo "runtime,iteration,boot_time_sec,node,kernel,arch,instance_type,timestamp" > "$CSV"

for i in $(seq 1 $ITERATIONS); do
  local_ns="bench-gv-${i}"
  local_name="bench-gv-${i}"
  pod_name="${local_name}-0"
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  log "--- gVisor iteration $i / $ITERATIONS ---"

  # Create namespace
  kubectl create namespace "$local_ns" >/dev/null 2>&1 || true

  # Generate and apply
  yaml=$(gen_openclaw_yaml "$local_name" "$local_ns" "gvisor")

  t1=$(date +%s%N)
  echo "$yaml" | kubectl apply -f - >/dev/null 2>&1

  log "Waiting for pod $pod_name to be Ready (timeout 300s)..."
  if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$local_ns" --timeout=300s >/dev/null 2>&1; then
    log "First wait failed, retrying..."
    sleep 10
    if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$local_ns" --timeout=300s >/dev/null 2>&1; then
      log "ERROR: Pod $pod_name did not become Ready"
      kubectl get pods -n "$local_ns" -o wide >&2 || true
      kubectl describe pod "$pod_name" -n "$local_ns" 2>&2 | tail -30 || true
      echo "gvisor,$i,FAILED,$GVISOR_NODE,$NODE_KERNEL,$NODE_ARCH,$NODE_INSTANCE,$ts" >> "$CSV"
      cleanup_ns "$local_ns"
      sleep 5
      continue
    fi
  fi
  t2=$(date +%s%N)

  boot_ms=$(( (t2 - t1) / 1000000 ))
  boot_sec=$(echo "scale=2; $boot_ms / 1000" | bc)

  # Get kernel from inside pod
  pod_kernel=$(kubectl exec "$pod_name" -n "$local_ns" -c openclaw -- uname -r 2>/dev/null || echo "N/A")

  # Quick gateway health check
  gw_status=$(kubectl exec "$pod_name" -n "$local_ns" -c openclaw -- curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/healthz 2>/dev/null || echo "N/A")

  log "✅ Boot: ${boot_sec}s | Kernel: $pod_kernel | Gateway: $gw_status"
  echo "gvisor,$i,$boot_sec,$GVISOR_NODE,$pod_kernel,$NODE_ARCH,$NODE_INSTANCE,$ts" >> "$CSV"

  # Cleanup
  cleanup_ns "$local_ns"
  sleep 5
done

# ============================================================
# Summary
# ============================================================
log ""
log "=== Results ==="
cat "$CSV" >&2

# Calculate stats
boot_times=$(tail -n +2 "$CSV" | grep -v FAILED | cut -d, -f3)
count=$(echo "$boot_times" | wc -l)
if [[ $count -gt 0 ]]; then
  first=$(echo "$boot_times" | head -1)
  warm_avg=$(echo "$boot_times" | tail -n +2 | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
  all_avg=$(echo "$boot_times" | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
  log ""
  log "Cold boot (iter 1): ${first}s"
  log "Warm avg (iter 2-5): ${warm_avg}s"
  log "Overall avg: ${all_avg}s"
  log ""
  log "Note: Node is $NODE_ARCH ($NODE_INSTANCE), original Test 1 was x86 (m8i.4xlarge)"
fi

log "CSV saved to: $CSV"
