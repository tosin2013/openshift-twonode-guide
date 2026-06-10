#!/bin/bash
# Post-installation tuning for ODF on Two-Node OpenShift (TNF)
#
# Source: https://access.redhat.com/articles/7139231
# "Deploying ODF on a Two-Node OpenShift Cluster with Fencing and DRBD"
# ODF 4.21 Developer Preview
#
# Purpose: Reduce CSI driver resource requests so they fit within the tight
#          CPU budget of a 2-node cluster. Then delete stale Error/CrashLoop
#          CSI pods so replacements can schedule with the new lower requests.
#
# ⚠ Incident-driven hardening (2026-06-09):
#   After patching the driver CRs, stale Error-state CSI controller pods
#   retain their pre-patch CPU reservations and block replacement pods from
#   scheduling. This script now explicitly deletes those stale pods.
#   See: docs/hardening/odf-csi-cpu-starvation-v4.21-2026-06-09.md
#
# Run from the repository root:
#   bash scripts/update-csi-resources.sh
#
# Exit codes:
#   0 = patch applied and all CSI pods Running
#   1 = preflight check failed (ODF not ready for tuning)
#   2 = patch applied but pods did not recover within timeout

set -eu

KUBECONFIG="${KUBECONFIG:-${HOME}/generated_assets/twonode/auth/kubeconfig}"
NAMESPACE="openshift-storage"
RBD_DRIVER_NAME="openshift-storage.rbd.csi.ceph.com"
CEPHFS_DRIVER_NAME="openshift-storage.cephfs.csi.ceph.com"
WAIT_TIMEOUT_SECONDS=300   # 5 minutes

# ── Guard clause 1: KUBECONFIG must be set and API reachable ─────────────────
echo "--- Preflight: Kubernetes API ---"
if ! oc get ns "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" &>/dev/null; then
  echo "❌ Cannot reach Kubernetes API or namespace '${NAMESPACE}' does not exist."
  echo "   Set KUBECONFIG or deploy ODF before running this script."
  exit 1
fi
echo "✅ Kubernetes API reachable, namespace ${NAMESPACE} exists"

# ── Guard clause 2: CSI driver CRs must exist ────────────────────────────────
echo "--- Preflight: CSI driver CRs ---"
for DRIVER in "${RBD_DRIVER_NAME}" "${CEPHFS_DRIVER_NAME}"; do
  if ! oc get driver "${DRIVER}" -n "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" &>/dev/null; then
    echo "❌ CSI driver CR '${DRIVER}' not found in ${NAMESPACE}."
    echo "   ODF may not be fully installed yet. Wait for StorageCluster to progress."
    exit 1
  fi
done
echo "✅ Both CSI driver CRs present (rbd + cephfs)"

# ── Guard clause 3: Warn if node CPU is not strained ─────────────────────────
echo "--- Preflight: Node CPU check ---"
NODE1_CPU=$(oc describe node openshift-node1 --kubeconfig="${KUBECONFIG}" 2>/dev/null | \
  awk '/cpu.*Requests/{found=1} found && /cpu/{print; exit}' || echo "unknown")
echo "ℹ️  node1 CPU allocation: ${NODE1_CPU} (patching regardless)"

# ── Patch RBD CSI driver ─────────────────────────────────────────────────────
echo ""
echo "--- Patching RBD CSI driver resources ---"
oc patch driver "${RBD_DRIVER_NAME}" \
  -n "${NAMESPACE}" \
  --kubeconfig="${KUBECONFIG}" \
  --type=merge \
  -p '{
  "spec": {
    "controllerPlugin": {
      "replicas": 1,
      "resources": {
        "addons":        {"requests": {"cpu": "50m",  "memory": "50Mi"}},
        "attacher":      {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "logRotator":    {"requests": {"cpu": "10m",  "memory": "32Mi"}},
        "omapGenerator": {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "plugin":        {"requests": {"cpu": "100m", "memory": "100Mi"}},
        "provisioner":   {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "resizer":       {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "snapshotter":   {"requests": {"cpu": "25m",  "memory": "50Mi"}}
      }
    },
    "nodePlugin": {
      "resources": {
        "addons":      {"requests": {"cpu": "50m", "memory": "50Mi"}},
        "registrar":   {"requests": {"cpu": "10m", "memory": "10Mi"}},
        "logRotator":  {"requests": {"cpu": "10m", "memory": "32Mi"}},
        "plugin":      {"requests": {"cpu": "50m", "memory": "100Mi"}}
      }
    }
  }
}'
echo "✅ RBD CSI driver patched"

# ── Patch CephFS CSI driver ───────────────────────────────────────────────────
echo ""
echo "--- Patching CephFS CSI driver resources ---"
oc patch driver "${CEPHFS_DRIVER_NAME}" \
  -n "${NAMESPACE}" \
  --kubeconfig="${KUBECONFIG}" \
  --type=merge \
  -p '{
  "spec": {
    "controllerPlugin": {
      "replicas": 1,
      "resources": {
        "addons":        {"requests": {"cpu": "50m",  "memory": "50Mi"}},
        "attacher":      {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "logRotator":    {"requests": {"cpu": "10m",  "memory": "32Mi"}},
        "omapGenerator": {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "plugin":        {"requests": {"cpu": "100m", "memory": "100Mi"}},
        "provisioner":   {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "resizer":       {"requests": {"cpu": "25m",  "memory": "50Mi"}},
        "snapshotter":   {"requests": {"cpu": "25m",  "memory": "50Mi"}}
      }
    },
    "nodePlugin": {
      "resources": {
        "addons":      {"requests": {"cpu": "50m", "memory": "50Mi"}},
        "registrar":   {"requests": {"cpu": "10m", "memory": "10Mi"}},
        "logRotator":  {"requests": {"cpu": "10m", "memory": "32Mi"}},
        "plugin":      {"requests": {"cpu": "50m", "memory": "100Mi"}}
      }
    }
  }
}'
echo "✅ CephFS CSI driver patched"

# ── Delete stale Error/CrashLoop CSI pods ────────────────────────────────────
# CRITICAL: After patching driver CRs, pods currently in Error or CrashLoopBackOff
# retain their pre-patch CPU reservations. They must be deleted so the CSI Addons
# operator can create replacement pods with the new lower resource requests.
echo ""
echo "--- Deleting stale Error/CrashLoop CSI pods ---"
STALE_PODS=$(oc get pods -n "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" \
  --no-headers 2>/dev/null | \
  grep -E "ctrlplugin|nodeplugin" | \
  grep -v "Running\|Completed" | \
  awk '{print $1}' || true)

if [[ -z "${STALE_PODS}" ]]; then
  echo "✅ No stale CSI pods found — all already Running"
else
  echo "   Deleting stale pods: $(echo "${STALE_PODS}" | tr '\n' ' ')"
  echo "${STALE_PODS}" | xargs -r oc delete pod -n "${NAMESPACE}" \
    --kubeconfig="${KUBECONFIG}" \
    --force --grace-period=0 2>/dev/null || true
  echo "✅ Stale pods deleted — replacements will schedule with new resource limits"
fi

# ── Wait for CSI pods to reach Running ───────────────────────────────────────
echo ""
echo "--- Waiting for CSI pods to reach Running (timeout: ${WAIT_TIMEOUT_SECONDS}s) ---"
ELAPSED=0
INTERVAL=10
while [[ ${ELAPSED} -lt ${WAIT_TIMEOUT_SECONDS} ]]; do
  NOT_READY=$(oc get pods -n "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" \
    --no-headers 2>/dev/null | \
    grep -E "ctrlplugin|nodeplugin" | \
    grep -v "Running\|Completed" | \
    awk '{print $1}' || true)
  if [[ -z "${NOT_READY}" ]]; then
    echo "✅ All CSI pods Running"
    break
  fi
  echo "   ${ELAPSED}s: waiting for: $(echo "${NOT_READY}" | tr '\n' ' ')"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${WAIT_TIMEOUT_SECONDS} ]]; then
  echo "⚠️  Timeout after ${WAIT_TIMEOUT_SECONDS}s — some CSI pods still not Running."
  echo "   Check node CPU allocation:"
  echo "     oc describe node openshift-node1 | grep -A8 'Allocated resources'"
  echo "   Check for Insufficient cpu events:"
  echo "     oc describe pod -n ${NAMESPACE} \$(oc get pod -n ${NAMESPACE} --no-headers | grep -v Running | head -1 | awk '{print \$1}')"
  exit 2
fi

# ── Final verification ────────────────────────────────────────────────────────
echo ""
echo "--- Final verification ---"
RUNNING=$(oc get pods -n "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" \
  --no-headers 2>/dev/null | grep "Running" | wc -l)
echo "ℹ️  ${RUNNING} pods Running in ${NAMESPACE}"

CEPH_HEALTH=$(oc get cephcluster -n "${NAMESPACE}" --kubeconfig="${KUBECONFIG}" \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "UNKNOWN")
if [[ "${CEPH_HEALTH}" == "HEALTH_OK" ]]; then
  echo "✅ CephCluster: HEALTH_OK"
else
  echo "⚠️  CephCluster: ${CEPH_HEALTH} — may recover in a few minutes"
fi

echo ""
echo "✅ CSI resource tuning complete."
echo "   If ODF pods are still Pending, check:"
echo "     oc describe pod -n ${NAMESPACE} <pending-pod>"
echo "   For Insufficient cpu: node1 may need further tuning or a pod restart cycle."
