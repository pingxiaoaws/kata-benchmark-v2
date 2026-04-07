#!/bin/bash
# v2-lib.sh - Shared functions for Kata Benchmark v2 (CRD-based)
set -euo pipefail

RESULTS_DIR="/home/ec2-user/benchmark/results"

# Node lists
BENCH_NODES=(
  "ip-172-31-18-241.us-west-2.compute.internal"
  "ip-172-31-19-254.us-west-2.compute.internal"
  "ip-172-31-19-97.us-west-2.compute.internal"
  "ip-172-31-21-152.us-west-2.compute.internal"
  "ip-172-31-22-253.us-west-2.compute.internal"
  "ip-172-31-24-12.us-west-2.compute.internal"
  "ip-172-31-25-251.us-west-2.compute.internal"
  "ip-172-31-27-93.us-west-2.compute.internal"
)
UNTAINTED_NODE="ip-172-31-29-155.us-west-2.compute.internal"
OVERSELL_NODE="ip-172-31-18-5.us-west-2.compute.internal"
PRIMARY_NODE="${BENCH_NODES[0]}"

# All m8i.4xlarge nodes for Test 3 (9 tainted + 1 untainted)
# Note: ip-172-31-28-206 excluded - no workload-type=kata label
ALL_M8I_NODES=(
  "${BENCH_NODES[@]}"
  "$UNTAINTED_NODE"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Generate OpenClawInstance YAML
# Usage: gen_instance_yaml <name> <ns> <runtime> <taint_key> [node_name] [persist]
gen_instance_yaml() {
  local name="$1" ns="$2" runtime="$3" taint_key="${4:-kata-benchmark}" node_name="${5:-}" persist="${6:-true}"

  local runtime_line=""
  [[ "$runtime" != "runc" ]] && runtime_line="    runtimeClassName: ${runtime}"

  local nodeselector=""
  if [[ -n "$node_name" ]]; then
    nodeselector="    nodeSelector:
      workload-type: kata
      kubernetes.io/hostname: ${node_name}"
  else
    nodeselector="    nodeSelector:
      workload-type: kata"
  fi

  local tolerations=""
  if [[ "$taint_key" != "none" ]]; then
    tolerations="    tolerations:
    - key: ${taint_key}
      operator: Equal
      value: 'true'
      effect: NoSchedule"
  fi

  cat <<EOF
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: kata-benchmark-v2
spec:
  availability:
${runtime_line}
${nodeselector}
${tolerations}
  config:
    format: json
    mergeMode: overwrite
    raw:
      gateway:
        trustedProxies:
        - 0.0.0.0/0
  env:
  - name: AWS_REGION
    value: us-west-2
  - name: AWS_DEFAULT_REGION
    value: us-west-2
  gateway: {}
  image:
    pullPolicy: IfNotPresent
    repository: ghcr.io/openclaw/openclaw
    tag: latest
  networking:
    ingress:
      enabled: false
    service:
      type: ClusterIP
  observability:
    logging:
      format: json
      level: info
    metrics:
      enabled: false
  resources:
    limits:
      cpu: "1"
      memory: 3Gi
    requests:
      cpu: 800m
      memory: 2Gi
  security:
    containerSecurityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
    networkPolicy:
      allowDNS: true
      enabled: true
    podSecurityContext:
      fsGroup: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      runAsUser: 1000
    rbac:
      createServiceAccount: true
  storage:
    persistence:
      accessModes:
      - ReadWriteOnce
      enabled: ${persist}
      size: 10Gi
      storageClass: gp3
  chromium:
    enabled: false
  ollama:
    enabled: false
  tailscale:
    enabled: false
  webTerminal:
    enabled: false
  autoUpdate:
    enabled: false
  runtimeDeps: {}
EOF
}

# Create namespace + apply instance, echo start timestamp (ms)
create_instance() {
  local name="$1" ns="$2" runtime="$3" taint_key="${4:-kata-benchmark}" node_name="${5:-}" persist="${6:-true}"
  kubectl create namespace "$ns" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
  local yaml
  yaml=$(gen_instance_yaml "$name" "$ns" "$runtime" "$taint_key" "$node_name" "$persist")
  local start_ms
  start_ms=$(date +%s%3N)
  echo "$yaml" | kubectl apply -f - >/dev/null 2>&1
  echo "$start_ms"
}

# Wait for pod Ready (2/2), echo end timestamp (ms) or "TIMEOUT"
wait_instance_ready() {
  local name="$1" ns="$2" timeout="${3:-600}"
  local deadline=$(($(date +%s) + timeout))
  while [[ $(date +%s) -lt $deadline ]]; do
    # Check if pod exists and all containers are ready
    local ready_count total_count
    ready_count=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || echo 0)
    total_count=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.containerStatuses}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [[ "$total_count" -gt 0 && "$ready_count" == "$total_count" ]]; then
      echo "$(date +%s%3N)"
      return 0
    fi
    sleep 2
  done
  echo "TIMEOUT"
  return 1
}

# Cleanup namespace
cleanup_ns() {
  local ns="$1"
  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Wait for namespace deletion
wait_ns_gone() {
  local ns="$1" timeout="${2:-180}"
  local deadline=$(($(date +%s) + timeout))
  while [[ $(date +%s) -lt $deadline ]]; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  log "WARN: namespace $ns still terminating after ${timeout}s"
}

# Get pod node
get_pod_node() {
  local ns="$1" name="$2"
  kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "unknown"
}

# Get pod IP
get_pod_ip() {
  local ns="$1" name="$2"
  kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo ""
}

# Get pod resource usage via kubectl top
get_pod_resources() {
  local ns="$1"
  kubectl top pods -n "$ns" --no-headers 2>/dev/null || echo "unavailable"
}

# Check gateway via kubectl exec
check_gateway_health() {
  local ns="$1" name="$2"
  local pod_name
  pod_name=$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance="$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$pod_name" ]]; then
    echo "NO_POD"
    return 1
  fi
  # Use wget from within the pod
  if kubectl exec -n "$ns" "$pod_name" -c openclaw -- wget -q --spider --timeout=5 http://127.0.0.1:18789/ 2>/dev/null; then
    echo "OK"
    return 0
  else
    echo "FAIL"
    return 1
  fi
}

# Count OOM events in namespace
count_oom_events() {
  local ns="$1"
  kubectl get events -n "$ns" --field-selector reason=OOMKilled --no-headers 2>/dev/null | wc -l
}

# Count restarts
count_restarts() {
  local ns="$1"
  kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1}END{print s+0}'
}
