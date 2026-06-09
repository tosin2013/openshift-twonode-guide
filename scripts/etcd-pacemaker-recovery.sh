#!/usr/bin/env bash
# etcd-pacemaker-recovery.sh
# Emergency recovery for TNF etcd "panic: removed all voters" incident.
#
# Use when: Kubernetes API is completely unresponsive after etcd lost quorum
# due to the CEO removing a node from the etcd member list.
#
# See: docs/adrs/011-odf-tnf-demo5-fencing-procedure.md
#      docs/adrs/004-etcd-outside-cluster.md (Incident-Driven Constraint section)
#
# Usage:
#   bash scripts/etcd-pacemaker-recovery.sh \
#     --clean-node openshift-node1 \
#     --corrupt-node openshift-node2 \
#     --clean-node-ip 192.168.49.21 \
#     --corrupt-node-ip 192.168.49.22

set -euo pipefail

SSH_KEY="${SSH_KEY:-${HOME}/.ssh/openshift-twonode-ed25519}"
CLEAN_NODE=""
CORRUPT_NODE=""
CLEAN_IP=""
CORRUPT_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-node)       CLEAN_NODE="$2";   shift 2 ;;
    --corrupt-node)     CORRUPT_NODE="$2"; shift 2 ;;
    --clean-node-ip)    CLEAN_IP="$2";     shift 2 ;;
    --corrupt-node-ip)  CORRUPT_IP="$2";   shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "${CLEAN_NODE}" || -z "${CORRUPT_NODE}" || -z "${CLEAN_IP}" || -z "${CORRUPT_IP}" ]]; then
  echo "Usage: $0 --clean-node <name> --corrupt-node <name> --clean-node-ip <ip> --corrupt-node-ip <ip>"
  echo ""
  echo "Identify the clean vs corrupt node by checking exit codes:"
  echo "  'Exited (0)' = clean WAL data  → use as --clean-node"
  echo "  'Exited (2)' = panic/corrupted → use as --corrupt-node"
  echo ""
  echo "Check exit codes:"
  echo "  for IP in 192.168.49.21 192.168.49.22; do"
  echo "    echo --- \$IP ---"
  echo "    ssh core@\$IP 'sudo podman ps -a --filter \"name=etcd\" --format \"{{.Status}}\"'"
  echo "  done"
  exit 1
fi

log()  { echo "$(date +%H:%M:%S) [RECOVERY] $*"; }
fail() { echo "$(date +%H:%M:%S) [ERROR]    $*" >&2; exit 1; }
ssh_clean()   { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no core@"${CLEAN_IP}"   "$@"; }
ssh_corrupt() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no core@"${CORRUPT_IP}" "$@"; }

log "=== TNF etcd Pacemaker Recovery ==="
log "Clean node:   ${CLEAN_NODE} (${CLEAN_IP})"
log "Corrupt node: ${CORRUPT_NODE} (${CORRUPT_IP})"
echo ""

# ── Step 1: Confirm etcd container exit codes ────────────────────────────────
log "Step 1: Confirming etcd container states..."

CLEAN_STATUS=$(ssh_clean "sudo podman ps -a --filter 'name=etcd' --format '{{.Status}}' 2>/dev/null" 2>/dev/null || echo "UNKNOWN")
CORRUPT_STATUS=$(ssh_corrupt "sudo podman ps -a --filter 'name=etcd' --format '{{.Status}}' 2>/dev/null" 2>/dev/null || echo "UNKNOWN")

log "  ${CLEAN_NODE}:   etcd container status = ${CLEAN_STATUS}"
log "  ${CORRUPT_NODE}: etcd container status = ${CORRUPT_STATUS}"

if echo "${CLEAN_STATUS}" | grep -q "Exited (2)"; then
  fail "${CLEAN_NODE} shows 'Exited (2)' — this is the corrupt node, not the clean one. Swap --clean-node and --corrupt-node."
fi
if echo "${CORRUPT_STATUS}" | grep -q "Exited (0)"; then
  fail "${CORRUPT_NODE} shows 'Exited (0)' — this looks like the clean node. Swap --clean-node and --corrupt-node."
fi

# ── Step 2: Wipe corrupt member directory ───────────────────────────────────
log ""
log "Step 2: Wiping corrupt etcd member directory on ${CORRUPT_NODE}..."
ssh_corrupt "sudo rm -rf /var/lib/etcd/member"
REMAINING=$(ssh_corrupt "sudo ls /var/lib/etcd/ 2>/dev/null" || true)
log "  /var/lib/etcd/ on ${CORRUPT_NODE} now contains: ${REMAINING}"

# ── Step 3: Set force_new_cluster Pacemaker attribute ────────────────────────
log ""
log "Step 3: Setting force_new_cluster Pacemaker attribute on ${CLEAN_NODE}..."
ssh_clean "sudo crm_attribute --lifetime reboot \
  --node ${CLEAN_NODE} \
  --name force_new_cluster \
  --update ${CLEAN_NODE}"

ATTR_VALUE=$(ssh_clean "sudo crm_attribute --query --lifetime reboot \
  --node ${CLEAN_NODE} --name force_new_cluster 2>/dev/null | awk -F'value=' '{print \$2}'" 2>/dev/null || echo "?")
log "  Attribute value: ${ATTR_VALUE}"

if [[ "${ATTR_VALUE}" != *"${CLEAN_NODE}"* ]]; then
  fail "force_new_cluster attribute was not set correctly. Value: ${ATTR_VALUE}"
fi

# ── Step 4: Clean up and restart etcd via Pacemaker ─────────────────────────
log ""
log "Step 4: Triggering Pacemaker etcd restart (pcs resource cleanup etcd-clone)..."
ssh_clean "sudo pcs resource cleanup etcd-clone" &
CLEANUP_PID=$!

# Give it 90 seconds
sleep 90
kill "${CLEANUP_PID}" 2>/dev/null || true
wait "${CLEANUP_PID}" 2>/dev/null || true
log "  Cleanup command sent."

# ── Step 5: Monitor etcd recovery ────────────────────────────────────────────
log ""
log "Step 5: Monitoring etcd recovery (up to 5 minutes)..."
ETCD_OK=false
for i in $(seq 1 30); do
  ETCD_STATUS=$(ssh_clean "sudo pcs status 2>/dev/null | grep -A2 'etcd-clone'" 2>/dev/null || echo "?")
  PORT_CHECK=$(ssh_clean "sudo ss -tlnp 2>/dev/null | grep 2379" 2>/dev/null || echo "")
  log "  [${i}/30] Pacemaker: $(echo "${ETCD_STATUS}" | tr '\n' '|')"
  log "         Port 2379: ${PORT_CHECK:-NOT LISTENING}"
  if [[ -n "${PORT_CHECK}" ]] && echo "${ETCD_STATUS}" | grep -q "Started"; then
    log "  etcd is listening on port 2379 and Pacemaker shows Started."
    ETCD_OK=true
    break
  fi
  sleep 10
done

if [[ "${ETCD_OK}" == "false" ]]; then
  log ""
  log "etcd did not recover within 5 minutes. Current Pacemaker status:"
  ssh_clean "sudo pcs status 2>/dev/null" || true
  fail "etcd recovery timed out. Check Pacemaker logs: ssh core@${CLEAN_IP} sudo journalctl -u pacemaker --since '10 min ago' | grep etcd"
fi

# ── Step 6: Wait for kube-apiserver to reconnect ────────────────────────────
log ""
log "Step 6: Waiting for kube-apiserver to reconnect to etcd (~2 min)..."
export KUBECONFIG="${KUBECONFIG:-${HOME}/generated_assets/twonode/auth/kubeconfig}"
API_OK=false
for i in $(seq 1 24); do
  if oc get nodes --request-timeout=10s &>/dev/null; then
    log "  Kubernetes API is responsive!"
    API_OK=true
    break
  fi
  log "  [${i}/24] API still unreachable, waiting..."
  sleep 10
done

if [[ "${API_OK}" == "false" ]]; then
  fail "kube-apiserver did not reconnect within 4 minutes. Check kube-apiserver logs on ${CLEAN_NODE}."
fi

# ── Step 7: Final validation ─────────────────────────────────────────────────
log ""
log "=== Step 7: Final validation ==="
log "Nodes:"
oc get nodes 2>/dev/null || true
log ""
log "Pacemaker:"
ssh_clean "sudo pcs status 2>/dev/null | grep -E 'etcd|Online|Failed'" || true
log ""
log "ODF Ceph health:"
oc get cephcluster -n openshift-storage \
  -o custom-columns="NAME:.metadata.name,HEALTH:.status.ceph.health" 2>/dev/null || true
log ""
log "=== RECOVERY COMPLETE ==="
log "Verify the API is stable. If any out-of-service taints are still present, remove them:"
log "  oc adm taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-"
log "  oc adm taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule-"
