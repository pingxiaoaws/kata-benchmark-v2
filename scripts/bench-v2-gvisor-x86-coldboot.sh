#!/usr/bin/env bash
set -euo pipefail

# === gVisor Cold Boot Benchmark - x86 ===
# Same methodology as Test 1, on x86 m8i.4xlarge node
# Provides apple-to-apple comparison with runc/kata results

RESULTS_DIR="/home/ec2-user/kata-benchmark-v2/results"
mkdir -p "$RESULTS_DIR"

IMAGE_REPO="ghcr.io/openclaw/openclaw"
IMAGE_TAG="latest"

TARGET_NODE="ip-172-31-30-148.us-west-2.compute.internal"
CSV="$RESULTS_DIR/v2-test1-gvisor-x86-boot-time.csv"
ITERATIONS=5

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

gen_openclaw_yaml() {
  local name="$1" ns="$2"

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
    runtimeClassName: gvisor
    nodeSelector:
      kubernetes.io/hostname: $TARGET_NODE
    tolerations:
      - key: gvisor
        operator: Equal
        value: "true"
        effect: NoSchedule
      - key: kata-benchmark
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
  for attempt in $(seq 1 60); do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  log "Namespace $ns cleaned up"
}

# ============================================================
log "=== gVisor x86 Cold Boot Benchmark ==="
log "Node: $TARGET_NODE"
log "Iterations: $ITERATIONS"

# Verify node
if ! kubectl get node "$TARGET_NODE" --no-headers 2>/dev/null | grep -q "Ready"; then
  log "ERROR: Node $TARGET_NODE is not Ready"
  exit 1
fi

NODE_ARCH=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')
NODE_INSTANCE=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
NODE_KERNEL=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}')
log "Architecture: $NODE_ARCH | Instance: $NODE_INSTANCE | Kernel: $NODE_KERNEL"

# Clean up any leftovers
for i in $(seq 1 $ITERATIONS); do
  kubectl delete namespace "bench-gvx-${i}" --wait=false 2>/dev/null || true
done
sleep 5

# ============================================================
echo "runtime,iteration,boot_time_sec,node,kernel,arch,instance_type,timestamp" > "$CSV"

for i in $(seq 1 $ITERATIONS); do
  local_ns="bench-gvx-${i}"
  local_name="bench-gvx-${i}"
  pod_name="${local_name}-0"
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  log "--- gVisor x86 iteration $i / $ITERATIONS ---"

  kubectl create namespace "$local_ns" >/dev/null 2>&1 || true

  yaml=$(gen_openclaw_yaml "$local_name" "$local_ns")

  t1=$(date +%s%N)
  echo "$yaml" | kubectl apply -f - >/dev/null 2>&1

  log "Waiting for pod $pod_name to be Ready (timeout 300s)..."
  if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$local_ns" --timeout=300s >/dev/null 2>&1; then
    log "First wait failed, retrying..."
    sleep 10
    if ! kubectl wait --for=condition=Ready "pod/$pod_name" -n "$local_ns" --timeout=300s >/dev/null 2>&1; then
      log "ERROR: Pod $pod_name did not become Ready"
      kubectl get pods -n "$local_ns" -o wide >&2 || true
      kubectl describe pod "$pod_name" -n "$local_ns" 2>&1 | tail -30 || true
      echo "gvisor-x86,$i,FAILED,$TARGET_NODE,$NODE_KERNEL,$NODE_ARCH,$NODE_INSTANCE,$ts" >> "$CSV"
      cleanup_ns "$local_ns"
      sleep 5
      continue
    fi
  fi
  t2=$(date +%s%N)

  boot_ms=$(( (t2 - t1) / 1000000 ))
  boot_sec=$(echo "scale=2; $boot_ms / 1000" | bc)

  pod_kernel=$(kubectl exec "$pod_name" -n "$local_ns" -c openclaw -- uname -r 2>/dev/null || echo "N/A")
  gw_status=$(kubectl exec "$pod_name" -n "$local_ns" -c openclaw -- curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/healthz 2>/dev/null || echo "N/A")

  log "✅ Boot: ${boot_sec}s | Kernel: $pod_kernel | Gateway: $gw_status"
  echo "gvisor-x86,$i,$boot_sec,$TARGET_NODE,$pod_kernel,$NODE_ARCH,$NODE_INSTANCE,$ts" >> "$CSV"

  cleanup_ns "$local_ns"
  sleep 5
done

# ============================================================
log ""
log "=== Results ==="
cat "$CSV" >&2

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
fi

log "CSV saved to: $CSV"
