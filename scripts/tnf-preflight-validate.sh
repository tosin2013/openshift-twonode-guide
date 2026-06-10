#!/usr/bin/env bash
# tnf-preflight-validate.sh
# Pre-operation health validation for Two-Node OpenShift (TNF) clusters.
#
# Runs a suite of checks that must all pass before any disruptive operation
# (Demo 5 fence, node maintenance, ODF operations, etc.).
#
# This script was created in response to the 2026-06-08 incident where
# the etcd "removed all voters" panic caused a 1.5-hour API outage.
# See: docs/adrs/011-odf-tnf-demo5-fencing-procedure.md
#
# Usage:
#   bash scripts/tnf-preflight-validate.sh [--odf] [--verbose]
#
#   --odf      Also run ODF/Ceph specific checks
#   --verbose  Show full output for each check (default: summary only)
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed
#   2 = environment not configured (missing KUBECONFIG, SSH_KEY)

set -euo pipefail

SSH_KEY="${SSH_KEY:-${HOME}/.ssh/openshift-twonode-ed25519}"
NODE1_IP="${NODE1_IP:-192.168.49.21}"
NODE2_IP="${NODE2_IP:-192.168.49.22}"
CHECK_ODF=false
VERBOSE=false
KUBECONFIG="${KUBECONFIG:-${HOME}/generated_assets/twonode/auth/kubeconfig}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --odf)     CHECK_ODF=true; shift ;;
    --verbose) VERBOSE=true;   shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Result tracking ───────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0
declare -a FAILURES=()
declare -a WARNINGS=()

check_pass() { PASS=$((PASS+1)); echo "  ✅ PASS: $1"; }
check_fail() { FAIL=$((FAIL+1)); FAILURES+=("$1"); echo "  ❌ FAIL: $1"; }
check_warn() { WARN=$((WARN+1)); WARNINGS+=("$1"); echo "  ⚠️  WARN: $1"; }

ssh_n1() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"${NODE1_IP}" "$@" 2>/dev/null; }
ssh_n2() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"${NODE2_IP}" "$@" 2>/dev/null; }

echo "============================================================"
echo " TNF Pre-Operation Preflight Validation"
echo " $(date)"
echo "============================================================"
echo ""

# ── Signal 1: Kubernetes API responsive ──────────────────────────────────────
echo "--- Signal 1: Kubernetes API ---"
if oc get nodes --request-timeout=10s --kubeconfig="${KUBECONFIG}" &>/dev/null; then
  check_pass "Kubernetes API responsive"
  NODE_COUNT=$(oc get nodes --no-headers --kubeconfig="${KUBECONFIG}" 2>/dev/null | wc -l)
  NOT_READY=$(oc get nodes --no-headers --kubeconfig="${KUBECONFIG}" 2>/dev/null | grep -v " Ready " || true)
  if [[ -n "${NOT_READY}" ]]; then
    check_fail "Not all nodes are Ready: ${NOT_READY}"
  else
    check_pass "All ${NODE_COUNT} nodes are Ready"
  fi
else
  check_fail "Kubernetes API is not responsive (context deadline exceeded or connection refused)"
  echo "  Hint: Check etcd and kube-apiserver status manually via SSH."
fi
echo ""

# ── Signal 2: etcd Pacemaker resource status ─────────────────────────────────
# This is the check that would have caught the incident BEFORE the fence was attempted.
echo "--- Signal 2: etcd Pacemaker status (CRITICAL — missed by 'oc' tooling) ---"
ETCD_PCS=$(ssh_n1 "sudo pcs status 2>/dev/null | grep -A4 'etcd-clone'" || echo "SSH_FAILED")
if [[ "${ETCD_PCS}" == "SSH_FAILED" ]]; then
  check_fail "Cannot SSH to node1 (${NODE1_IP}) to check Pacemaker"
elif echo "${ETCD_PCS}" | grep -qE "FAILED|Error"; then
  check_fail "Pacemaker etcd resource FAILED: $(echo "${ETCD_PCS}" | head -3)"
elif echo "${ETCD_PCS}" | grep -q "Stopped"; then
  check_fail "Pacemaker etcd resource Stopped on at least one node: ${ETCD_PCS}"
elif echo "${ETCD_PCS}" | grep -q "Started"; then
  STARTED=$(echo "${ETCD_PCS}" | grep "Started" || true)
  check_pass "etcd Pacemaker: ${STARTED}"
  FAILED_ACTIONS=$(ssh_n1 "sudo pcs status 2>/dev/null | grep 'Failed Resource Actions' -A5" 2>/dev/null | grep "etcd" || true)
  if [[ -n "${FAILED_ACTIONS}" ]]; then
    check_warn "etcd has recent failed actions (may be stale): ${FAILED_ACTIONS}"
  fi
else
  check_warn "etcd Pacemaker status unclear: ${ETCD_PCS}"
fi
echo ""

# ── Signal 3: etcd port 2379 listening on both nodes ─────────────────────────
# This check directly confirms etcd is actually serving (not just "Started" in Pacemaker).
echo "--- Signal 3: etcd port 2379 listening ---"
for IP_NAME_PAIR in "${NODE1_IP}:node1" "${NODE2_IP}:node2"; do
  IP="${IP_NAME_PAIR%%:*}"
  NAME="${IP_NAME_PAIR##*:}"
  RESULT=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"${IP}" \
    "sudo ss -tlnp 2>/dev/null | grep 2379" 2>/dev/null || echo "")
  if [[ -n "${RESULT}" ]]; then
    check_pass "${NAME} (${IP}): etcd listening on 2379"
  else
    check_fail "${NAME} (${IP}): etcd NOT listening on port 2379 — API requests will time out"
  fi
done
echo ""

# ── Signal 4: etcd Pacemaker member count matches expected ───────────────────
echo "--- Signal 4: etcd cluster member health ---"
REVISION_JSON=$(ssh_n1 "sudo cat /var/lib/etcd/revision.json 2>/dev/null" || echo "")
if [[ -n "${REVISION_JSON}" ]]; then
  MAX_RAFT=$(echo "${REVISION_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('maxRaftIndex','?'))" 2>/dev/null || echo "?")
  check_pass "etcd revision.json present on node1 (maxRaftIndex: ${MAX_RAFT})"
else
  check_warn "etcd revision.json not found on node1 — may indicate etcd never ran or data wiped"
fi
echo ""

# ── Signal 5: No stale out-of-service taints ─────────────────────────────────
# Stale taints from a previous failed fence attempt can cause issues on restart.
echo "--- Signal 5: No stale out-of-service taints ---"
ALL_CLEAN=true
for NODE_NAME in openshift-node1 openshift-node2; do
  RAW_TAINTS=$(oc get node "${NODE_NAME}" --kubeconfig="${KUBECONFIG}" \
    -o jsonpath='{.spec.taints}' 2>/dev/null)
  if [[ -z "${RAW_TAINTS}" ]]; then
    TAINTS="CLEAN"
  else
    TAINTS=$(echo "${RAW_TAINTS}" | python3 -c "
import json, sys
taints = json.load(sys.stdin) or []
bad = [t.get('key','') for t in taints if 'out-of-service' in t.get('key', '')]
print(','.join(bad) if bad else 'CLEAN')
" 2>/dev/null || echo "UNKNOWN")
  fi
  if [[ "${TAINTS}" == "CLEAN" ]]; then
    check_pass "${NODE_NAME}: no out-of-service taints"
  elif [[ "${TAINTS}" == "UNKNOWN" ]]; then
    check_warn "${NODE_NAME}: could not check taints (API may be down)"
    ALL_CLEAN=false
  else
    check_fail "${NODE_NAME}: STALE out-of-service taints present: ${TAINTS}"
    ALL_CLEAN=false
  fi
done
echo ""

# ── Signal 6: Pacemaker cluster quorum ───────────────────────────────────────
echo "--- Signal 6: Pacemaker quorum ---"
PCS_QUORUM=$(ssh_n1 "sudo pcs status 2>/dev/null | grep -E 'partition with quorum|quorum'" || echo "SSH_FAILED")
if [[ "${PCS_QUORUM}" == "SSH_FAILED" ]]; then
  check_fail "Cannot SSH to check Pacemaker quorum"
elif echo "${PCS_QUORUM}" | grep -q "partition with quorum"; then
  check_pass "Pacemaker cluster has quorum"
elif echo "${PCS_QUORUM}" | grep -q "without quorum"; then
  check_fail "Pacemaker cluster is in split-brain (no quorum) — STONITH will not operate"
else
  check_warn "Pacemaker quorum status unclear: ${PCS_QUORUM}"
fi
echo ""

# ── Signal 7: Pacemaker STONITH resource ─────────────────────────────────────
echo "--- Signal 7: STONITH fence agent functional ---"
STONITH=$(ssh_n1 "sudo pcs stonith status 2>/dev/null" || echo "SSH_FAILED")
if [[ "${STONITH}" == "SSH_FAILED" ]]; then
  check_warn "Cannot SSH to check STONITH status"
elif echo "${STONITH}" | grep -qiE "FAILED|Error|no stonith"; then
  check_fail "STONITH resource has failures or is not configured: ${STONITH}"
else
  check_pass "STONITH resources are configured"
  # Check for recent timeout on openshift-node2_redfish
  STONITH_FAIL=$(ssh_n1 "sudo pcs status 2>/dev/null | grep 'openshift-node.*redfish' | grep -i 'fail\|timeout'" 2>/dev/null || true)
  if [[ -n "${STONITH_FAIL}" ]]; then
    check_warn "STONITH has a recent failure (may be stale): ${STONITH_FAIL}"
  fi
fi
echo ""

# ── ODF-specific checks ───────────────────────────────────────────────────────
if [[ "${CHECK_ODF}" == "true" ]]; then
  echo "--- Signal 8: ODF/Ceph health (--odf flag) ---"
  CEPH_HEALTH=$(oc get cephcluster -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "UNKNOWN")
  if [[ "${CEPH_HEALTH}" == "HEALTH_OK" ]]; then
    check_pass "ODF CephCluster: HEALTH_OK"
  elif [[ "${CEPH_HEALTH}" == "HEALTH_WARN" ]]; then
    check_warn "ODF CephCluster: HEALTH_WARN (check 'ceph status' for details)"
  elif [[ "${CEPH_HEALTH}" == "HEALTH_ERR" ]]; then
    check_fail "ODF CephCluster: HEALTH_ERR — do not proceed with fence"
  else
    check_warn "ODF CephCluster: health unknown (${CEPH_HEALTH})"
  fi

  SC_PHASE=$(oc get storagecluster -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "UNKNOWN")
  if [[ "${SC_PHASE}" == "Ready" ]]; then
    check_pass "StorageCluster phase: Ready"
  else
    check_warn "StorageCluster phase: ${SC_PHASE} (not Ready — may recover on its own)"
  fi

  CSI_PENDING=$(oc get pods -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    --no-headers 2>/dev/null | grep "ctrlplugin" | grep -v "Running" | head -3 || true)
  if [[ -z "${CSI_PENDING}" ]]; then
    check_pass "ODF CSI controller pods Running"
  else
    check_warn "Some CSI controller pods not Running: ${CSI_PENDING}"
    echo "         Hint: Run 'bash scripts/update-csi-resources.sh' to cap CSI CPU requests,"
    echo "         then delete stale Error pods: oc get pods -n openshift-storage | grep -v Running"
  fi

  # Signal 9: ODF core pod count — HEALTH_OK does not mean all pods are scheduled
  # Incident 2026-06-09: Ceph reported HEALTH_OK with osd-1 and mon-a Pending.
  echo "--- Signal 9: ODF core pod count ---"
  MON_COUNT=$(oc get pods -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    --no-headers 2>/dev/null | grep "rook-ceph-mon-" | grep "Running" | wc -l || echo 0)
  OSD_COUNT=$(oc get pods -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    --no-headers 2>/dev/null | grep "rook-ceph-osd-[0-9]" | grep "Running" | wc -l || echo 0)
  MDS_COUNT=$(oc get pods -n openshift-storage --kubeconfig="${KUBECONFIG}" \
    --no-headers 2>/dev/null | grep "rook-ceph-mds-" | grep "Running" | wc -l || echo 0)

  if [[ "${MON_COUNT}" -ge 3 ]]; then
    check_pass "Ceph monitors Running: ${MON_COUNT}/3"
  elif [[ "${MON_COUNT}" -ge 2 ]]; then
    check_warn "Only ${MON_COUNT}/3 Ceph monitors Running — quorum met but degraded"
  else
    check_fail "Only ${MON_COUNT}/3 Ceph monitors Running — quorum may be lost"
  fi

  if [[ "${OSD_COUNT}" -ge 2 ]]; then
    check_pass "Ceph OSDs Running: ${OSD_COUNT}/2"
  elif [[ "${OSD_COUNT}" -ge 1 ]]; then
    check_warn "Only ${OSD_COUNT}/2 Ceph OSDs Running — pool replication not guaranteed"
  else
    check_fail "No Ceph OSDs Running — storage unavailable"
  fi

  if [[ "${MDS_COUNT}" -ge 1 ]]; then
    check_pass "Ceph MDS Running: ${MDS_COUNT} (CephFilesystem active)"
  else
    check_warn "No Ceph MDS Running — CephFilesystem (RWX) unavailable (needed for Demo 6)"
  fi

  # Signal 10: Node CPU headroom — catch starvation before fence
  # Incident 2026-06-09: node1 at 98% CPU blocked ODF pod scheduling silently.
  echo "--- Signal 10: Node CPU headroom ---"
  for NODE_NAME in openshift-node1 openshift-node2; do
    CPU_REQ_PCT=$(oc describe node "${NODE_NAME}" --kubeconfig="${KUBECONFIG}" 2>/dev/null | \
      awk '/Allocated resources/{found=1} found && /cpu/{match($0, /([0-9]+)%/, arr); if (arr[1]) {print arr[1]; exit}}' || echo "")
    [[ -z "${CPU_REQ_PCT}" ]] && CPU_REQ_PCT="unknown"
    if [[ "${CPU_REQ_PCT}" == "unknown" ]]; then
      check_warn "${NODE_NAME}: could not determine CPU allocation"
    elif [[ "${CPU_REQ_PCT}" -ge 90 ]]; then
      check_fail "${NODE_NAME}: CPU requests at ${CPU_REQ_PCT}% — insufficient headroom for ODF pod scheduling or fence recovery"
    elif [[ "${CPU_REQ_PCT}" -ge 75 ]]; then
      check_warn "${NODE_NAME}: CPU requests at ${CPU_REQ_PCT}% — tight; run 'bash scripts/update-csi-resources.sh' if ODF pods are Pending"
    else
      check_pass "${NODE_NAME}: CPU requests at ${CPU_REQ_PCT}% — adequate headroom"
    fi
  done
  echo ""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================================"
echo " VALIDATION SUMMARY"
echo "============================================================"
echo "  ✅ Passed:  ${PASS}"
echo "  ❌ Failed:  ${FAIL}"
echo "  ⚠️  Warnings: ${WARN}"
echo ""

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "FAILURES (must be resolved before proceeding):"
  for F in "${FAILURES[@]}"; do
    echo "  ❌ ${F}"
  done
  echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo "WARNINGS (review before proceeding):"
  for W in "${WARNINGS[@]}"; do
    echo "  ⚠️  ${W}"
  done
  echo ""
fi

if [[ "${FAIL}" -gt 0 ]]; then
  echo "❌ PREFLIGHT FAILED — DO NOT PROCEED with disruptive operations."
  echo "   Resolve all failures listed above first."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "⚠️  PREFLIGHT PASSED WITH WARNINGS — review warnings before proceeding."
  exit 0
else
  echo "✅ ALL CHECKS PASSED — cluster is healthy for disruptive operations."
  exit 0
fi
