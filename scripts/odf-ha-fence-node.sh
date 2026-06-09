#!/usr/bin/env bash
# odf-ha-fence-node.sh
# Safe 2-node TNF node fence + ODF HA validation sequence.
#
# Implements 011: out-of-service taints must only be applied AFTER
# Pacemaker STONITH has confirmed the node is powered off.
#
# Usage:
#   bash scripts/odf-ha-fence-node.sh --target openshift-node2 [--skip-preflight]
#
# Environment variables:
#   KUBECONFIG   - path to kubeconfig (required)
#   SSH_KEY      - path to SSH private key for node access (default: ~/.ssh/openshift-twonode-ed25519)
#   NODE1_IP     - IP of openshift-node1 (default: 192.168.49.21)
#   NODE2_IP     - IP of openshift-node2 (default: 192.168.49.22)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/openshift-twonode-ed25519}"
NODE1_IP="${NODE1_IP:-192.168.49.21}"
NODE2_IP="${NODE2_IP:-192.168.49.22}"
TARGET_NODE=""
SKIP_PREFLIGHT=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         TARGET_NODE="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "${TARGET_NODE}" ]]; then
  echo "ERROR: --target <node-name> is required (e.g. --target openshift-node2)"
  exit 1
fi

if [[ "${TARGET_NODE}" == "openshift-node1" ]]; then
  SURVIVOR_IP="${NODE2_IP}"
else
  SURVIVOR_IP="${NODE1_IP}"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "$(date +%H:%M:%S) [INFO]  $*"; }
warn() { echo "$(date +%H:%M:%S) [WARN]  $*" >&2; }
fail() { echo "$(date +%H:%M:%S) [ERROR] $*" >&2; exit 1; }
ssh_node() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no core@"${SURVIVOR_IP}" "$@"; }

# ── Phase 1: Pre-flight checks ────────────────────────────────────────────────
if [[ "${SKIP_PREFLIGHT}" == "false" ]]; then
  log "=== PHASE 1: Pre-flight checks ==="

  log "1.1 Kubernetes API responsive..."
  if ! oc get nodes --request-timeout=10s &>/dev/null; then
    fail "Kubernetes API is not responsive. Resolve API issues before attempting fence."
  fi
  log "     OK"

  log "1.2 Both nodes Ready..."
  NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v "Ready" | grep -v "^$" || true)
  if [[ -n "${NOT_READY}" ]]; then
    warn "Nodes not all Ready:\n${NOT_READY}"
    read -r -p "Continue anyway? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || exit 1
  else
    log "     OK"
  fi

  log "1.3 etcd Started on both nodes (Pacemaker)..."
  ETCD_STATUS=$(ssh_node "sudo pcs status 2>/dev/null | grep -A3 'etcd-clone'" 2>/dev/null || true)
  echo "${ETCD_STATUS}"
  if echo "${ETCD_STATUS}" | grep -qE "FAILED|Stopped"; then
    fail "etcd is not healthy in Pacemaker. Fix etcd before fencing. Run:\n  ssh core@${SURVIVOR_IP} sudo pcs status"
  fi
  log "     OK"

  log "1.4 etcd port 2379 listening on both nodes..."
  ETCD_OK=true
  for IP in "${NODE1_IP}" "${NODE2_IP}"; do
    RESULT=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no core@"${IP}" \
      "sudo ss -tlnp | grep 2379" 2>/dev/null || true)
    if [[ -z "${RESULT}" ]]; then
      warn "etcd NOT listening on 2379 at ${IP}"
      ETCD_OK=false
    fi
  done
  if [[ "${ETCD_OK}" == "false" ]]; then
    fail "etcd port 2379 not listening on all nodes. Do not fence until etcd is healthy."
  fi
  log "     OK"

  log "1.5 Pacemaker STONITH resource functional..."
  STONITH_STATUS=$(ssh_node "sudo pcs stonith status 2>/dev/null" 2>/dev/null || true)
  if echo "${STONITH_STATUS}" | grep -qiE "failed|error"; then
    warn "Pacemaker STONITH resource shows failures:\n${STONITH_STATUS}"
    read -r -p "Continue anyway? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || exit 1
  else
    log "     OK"
  fi

  log "1.6 ODF Ceph cluster healthy..."
  CEPH_HEALTH=$(oc get cephcluster -n openshift-storage \
    -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "UNKNOWN")
  if [[ "${CEPH_HEALTH}" != "HEALTH_OK" ]]; then
    warn "ODF Ceph health is ${CEPH_HEALTH} (not HEALTH_OK)"
    read -r -p "Continue anyway? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || exit 1
  else
    log "     OK"
  fi

  log "1.7 No stale out-of-service taints on ${TARGET_NODE}..."
  STALE_TAINTS=$(oc get node "${TARGET_NODE}" \
    -o jsonpath='{.spec.taints}' 2>/dev/null | \
    python3 -c "
import json, sys
taints = json.load(sys.stdin) or []
bad = [t for t in taints if 'out-of-service' in t.get('key', '')]
print('STALE:' + str(bad) if bad else 'CLEAN')
" 2>/dev/null || echo "UNKNOWN")
  if [[ "${STALE_TAINTS}" == STALE* ]]; then
    warn "Stale out-of-service taints found: ${STALE_TAINTS}"
    warn "Removing stale taints before proceeding..."
    oc adm taint nodes "${TARGET_NODE}" \
      node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- 2>/dev/null || true
    oc adm taint nodes "${TARGET_NODE}" \
      node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule- 2>/dev/null || true
    log "     Taints removed."
  else
    log "     OK"
  fi

  log "Pre-flight PASSED. Proceeding with fence operation."
fi

# ── Phase 2: Fence the target node (STONITH first) ───────────────────────────
log ""
log "=== PHASE 2: Fence ${TARGET_NODE} via Pacemaker STONITH ==="
log "Using fence_redfish on survivor node (${SURVIVOR_IP})..."

ssh_node "sudo pcs node fence ${TARGET_NODE}"

log "Waiting for ${TARGET_NODE} to go NotReady..."
for i in $(seq 1 18); do
  STATUS=$(oc get node "${TARGET_NODE}" --no-headers 2>/dev/null | awk '{print $2}' || echo "UNKNOWN")
  log "  ${TARGET_NODE} status=${STATUS}"
  if [[ "${STATUS}" == "NotReady" ]]; then
    log "${TARGET_NODE} is NotReady. Pacemaker fence confirmed."
    break
  fi
  if [[ "${i}" -eq 18 ]]; then
    warn "Timeout waiting for ${TARGET_NODE} to go NotReady. Check Pacemaker fence status."
    ssh_node "sudo pcs status" || true
    exit 1
  fi
  sleep 10
done

# ── Phase 3: Apply out-of-service taints (AFTER node is powered off) ─────────
log ""
log "=== PHASE 3: Apply out-of-service taints (RWO PVC release) ==="
log "Node is confirmed powered off. Applying taints to release RWO volume attachments..."

oc adm taint nodes "${TARGET_NODE}" \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
oc adm taint nodes "${TARGET_NODE}" \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule
log "Taints applied."

# ── Phase 4: Watch workload reschedule ───────────────────────────────────────
log ""
log "=== PHASE 4: Watch workload reschedule on survivor ==="
log "Polling for up to 5 minutes..."

for i in $(seq 1 30); do
  EVICTED=$(oc get pods -A --field-selector "spec.nodeName==${TARGET_NODE}" \
    --no-headers 2>/dev/null | grep -v "Completed" | wc -l || echo "?")
  LIVE=$(oc get pods -A --no-headers 2>/dev/null | grep -v "Completed" | wc -l || echo "?")
  log "  Remaining pods on fenced node: ${EVICTED} | Total running: ${LIVE}"
  [[ "${EVICTED}" == "0" ]] && { log "All pods evicted from ${TARGET_NODE}."; break; }
  sleep 10
done

# ── Phase 5: Print summary ────────────────────────────────────────────────────
log ""
log "=== PHASE 5: Status summary ==="
log "Nodes:"
oc get nodes 2>/dev/null || true
log ""
log "Pacemaker:"
ssh_node "sudo pcs status 2>/dev/null | grep -E 'etcd|kubelet|node|Online|Failed'" || true
log ""
log "ODF Ceph health:"
oc get cephcluster -n openshift-storage \
  -o custom-columns="NAME:.metadata.name,HEALTH:.status.ceph.health" 2>/dev/null || true

log ""
log "=== FENCE OPERATION COMPLETE ==="
log "Next steps:"
log "  1. Verify your test data is accessible from the surviving node"
log "  2. When ready to restore: sudo pcs node unstandby ${TARGET_NODE} (from survivor)"
log "  3. After restore, remove taints:"
log "       oc adm taint nodes ${TARGET_NODE} node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-"
log "       oc adm taint nodes ${TARGET_NODE} node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule-"
