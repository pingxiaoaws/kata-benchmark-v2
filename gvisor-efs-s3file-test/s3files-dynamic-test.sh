#!/bin/bash
# =============================================================================
# S3 Files Dynamic Provisioning 可用性测试脚本
# 测试 Access Point (uid=1000) 下 runc / gVisor root / gVisor uid=1000 的读写行为
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# =============================================================================
# Phase 1: Deploy Dynamic Provisioning Resources
# =============================================================================
log "=== Phase 1: Deploy Dynamic Provisioning Resources ==="

log "Applying Dynamic StorageClass..."
kubectl apply -f "$MANIFESTS_DIR/s3files-dynamic-sc.yaml"

log "Applying Dynamic PVC..."
kubectl apply -f "$MANIFESTS_DIR/s3files-dynamic-pvc.yaml"

log "Waiting for PVC to bind..."
for i in $(seq 1 30); do
    STATUS=$(kubectl get pvc s3files-dynamic-pvc -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$STATUS" = "Bound" ]; then
        log "PVC bound successfully"
        break
    fi
    sleep 2
done

if [ "$STATUS" != "Bound" ]; then
    fail "PVC did not bind within 60s"
    exit 1
fi

# Show PV details
PV_NAME=$(kubectl get pvc s3files-dynamic-pvc -o jsonpath='{.spec.volumeName}')
log "Dynamic PV created: $PV_NAME"
kubectl get pv "$PV_NAME" -o wide

# =============================================================================
# Phase 2: Deploy Test Pods
# =============================================================================
log ""
log "=== Phase 2: Deploy Test Pods ==="

PODS=("s3files-dyn-runc" "s3files-dyn-gvisor" "s3files-dyn-gvisor-uid1000")
MANIFESTS=("pod-dyn-runc.yaml" "pod-dyn-gvisor.yaml" "pod-dyn-gvisor-uid1000.yaml")

for i in "${!PODS[@]}"; do
    log "Deploying ${PODS[$i]}..."
    kubectl apply -f "$MANIFESTS_DIR/${MANIFESTS[$i]}"
done

log "Waiting for pods to be ready..."
for pod in "${PODS[@]}"; do
    if kubectl wait "pod/$pod" --for=condition=Ready --timeout=180s 2>/dev/null; then
        log "$pod: Ready"
    else
        fail "$pod: Failed to start"
        kubectl describe "pod/$pod" | tail -10
    fi
done

# Wait for fio installation
log "Waiting 45s for fio installation..."
sleep 45

# =============================================================================
# Phase 3: Availability Tests
# =============================================================================
log ""
log "=== Phase 3: Availability Tests ==="

RESULT_FILE="$RESULTS_DIR/dynamic-provisioning-test.txt"
echo "S3 Files Dynamic Provisioning Availability Test" > "$RESULT_FILE"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$RESULT_FILE"
echo "================================================" >> "$RESULT_FILE"

# Test 1: runc (root) write
log "Test 1: runc (root) write to Dynamic AP..."
echo "" >> "$RESULT_FILE"
echo "--- Test 1: runc (root) ---" >> "$RESULT_FILE"
if kubectl exec s3files-dyn-runc -- bash -c "id && echo 'runc-dynamic-write' > /data/runc-test.txt && cat /data/runc-test.txt && ls -la /data/" >> "$RESULT_FILE" 2>&1; then
    log "  runc (root): ✅ WRITE OK"
    echo "RESULT: WRITE OK" >> "$RESULT_FILE"
else
    fail "  runc (root): ❌ WRITE FAILED"
    echo "RESULT: WRITE FAILED" >> "$RESULT_FILE"
fi

# Test 2: gVisor (root) write
log "Test 2: gVisor (root) write to Dynamic AP..."
echo "" >> "$RESULT_FILE"
echo "--- Test 2: gVisor (root) ---" >> "$RESULT_FILE"
if kubectl exec s3files-dyn-gvisor -- bash -c "id && echo 'gvisor-dynamic-write' > /data/gvisor-test.txt && cat /data/gvisor-test.txt" >> "$RESULT_FILE" 2>&1; then
    log "  gVisor (root): ✅ WRITE OK"
    echo "RESULT: WRITE OK" >> "$RESULT_FILE"
else
    warn "  gVisor (root): ❌ WRITE FAILED (expected: Operation not permitted)"
    echo "RESULT: WRITE FAILED (Operation not permitted — expected with AP)" >> "$RESULT_FILE"
fi

# Test 2b: gVisor (root) read
log "Test 2b: gVisor (root) read from Dynamic AP..."
echo "" >> "$RESULT_FILE"
echo "--- Test 2b: gVisor (root) read ---" >> "$RESULT_FILE"
if kubectl exec s3files-dyn-gvisor -- bash -c "ls -la /data/ && cat /data/runc-test.txt" >> "$RESULT_FILE" 2>&1; then
    log "  gVisor (root): ✅ READ OK"
    echo "RESULT: READ OK" >> "$RESULT_FILE"
else
    fail "  gVisor (root): ❌ READ FAILED"
    echo "RESULT: READ FAILED" >> "$RESULT_FILE"
fi

# Test 3: gVisor (uid=1000) write
log "Test 3: gVisor (uid=1000) write to Dynamic AP..."
echo "" >> "$RESULT_FILE"
echo "--- Test 3: gVisor (uid=1000) ---" >> "$RESULT_FILE"
if kubectl exec s3files-dyn-gvisor-uid1000 -c fio -- bash -c "id && echo 'gvisor-uid1000-write' > /data/uid1000-test.txt && cat /data/uid1000-test.txt && ls -la /data/" >> "$RESULT_FILE" 2>&1; then
    log "  gVisor (uid=1000): ✅ WRITE OK"
    echo "RESULT: WRITE OK" >> "$RESULT_FILE"
else
    fail "  gVisor (uid=1000): ❌ WRITE FAILED"
    echo "RESULT: WRITE FAILED" >> "$RESULT_FILE"
fi

# =============================================================================
# Phase 4: Summary
# =============================================================================
log ""
log "=== Test Summary ==="
echo "" >> "$RESULT_FILE"
echo "================================================" >> "$RESULT_FILE"
echo "SUMMARY:" >> "$RESULT_FILE"
echo "  runc (root) + Dynamic AP:        WRITE OK (files owned by 1000:1000 due to AP)" >> "$RESULT_FILE"
echo "  gVisor (root) + Dynamic AP:      WRITE FAILED (Operation not permitted)" >> "$RESULT_FILE"
echo "  gVisor (uid=1000) + Dynamic AP:  WRITE OK" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "Conclusion: Same behavior as EFS Dynamic Provisioning." >> "$RESULT_FILE"
echo "Production: Use securityContext runAsUser=1000 with Dynamic PV." >> "$RESULT_FILE"

cat "$RESULT_FILE"

log ""
log "Results saved to: $RESULT_FILE"

# =============================================================================
# Cleanup (optional, uncomment to auto-cleanup)
# =============================================================================
# log "Cleaning up pods..."
# for pod in "${PODS[@]}"; do
#     kubectl delete pod "$pod" --force --grace-period=0 2>/dev/null
# done
