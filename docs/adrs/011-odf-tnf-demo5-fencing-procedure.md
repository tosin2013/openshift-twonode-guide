# 011. ODF TNF Demo 5 — Correct Node Fencing Procedure for HA Validation

**Status**: Accepted
**Date**: 2026-06-08
**Domain**: high-availability / fencing / odf-validation
**Source**: Incident — etcd panic during Demo 5 HA validation (2026-06-08)

---

## Context

The [ODF 4.21 TNF Developer Preview article](https://access.redhat.com/articles/7139231) documents
two separate operations that are easily confused:

1. **`out-of-service` taints** — Kubernetes signals that release RWO PVC volume attachments so the
   CSI driver can re-attach the volume on the surviving node.
2. **Node fencing** — Physically powering off the node via Pacemaker STONITH (Redfish/IPMI) to
   ensure the node cannot corrupt data or split-brain the cluster.

The Red Hat article presents these in a specific order (taints first, then fence) intended for a
**maintenance/planned shutdown** scenario on clusters with 3+ nodes, where the API server remains
accessible throughout. In a **2-node TNF cluster**, this order is unsafe.

### Why Order Matters on 2-Node TNF

On 2-node TNF, **both nodes run the kube-apiserver, etcd (via Pacemaker), and all control-plane
components**. When an `out-of-service` taint is applied to a live node:

1. The Kubernetes scheduler evicts workloads from the tainted node (intended)
2. The **Cluster Etcd Operator (CEO)** also reacts — it detects the node as "leaving" and
   **removes it from the etcd member list** (unintended side-effect)
3. In a 2-node etcd cluster, removing one member leaves 0 voters
4. The tainted node's etcd process panics: `panic: removed all voters`
5. The surviving node's etcd cannot form quorum (no leader, no running cluster)
6. The kube-apiserver becomes unresponsive — **the entire cluster API goes down**

This was observed on 2026-06-08 and caused a 1.5-hour API outage requiring etcd force-new-cluster
recovery.

---

## Decision

**For Demo 5 HA validation, always fence via `pcs node fence` (Pacemaker STONITH) BEFORE applying
`out-of-service` taints.**

The correct sequence is:

### Safe Fencing Sequence for 2-Node TNF Demo 5

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
TARGET_NODE="openshift-node2"   # the node to fence
SURVIVOR_NODE="openshift-node1" # the surviving node

# --- Step 1: Pre-flight health check ---
oc get nodes
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -E "etcd|Online|quorum"
# Confirm: both nodes Ready, etcd Started on both, Pacemaker has quorum

# --- Step 2: STONITH fence the node (powers it off via Redfish/IPMI) ---
# This is the only safe way to fence on 2-node TNF.
# Pacemaker coordinates the etcd member removal AFTER confirming the node is powered off.
ssh -i $SSH_KEY core@192.168.49.21 \
  sudo pcs node fence ${TARGET_NODE}

# Wait for the node to go NotReady in Kubernetes
echo "Waiting for ${TARGET_NODE} to go NotReady..."
for i in $(seq 1 24); do
  STATUS=$(oc get node ${TARGET_NODE} --no-headers 2>/dev/null | awk '{print $2}')
  echo "$(date +%H:%M:%S) ${TARGET_NODE} status=$STATUS"
  [[ "$STATUS" == "NotReady" ]] && break
  sleep 10
done

# Confirm Pacemaker shows the node as fenced/offline
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -E "etcd|node"

# --- Step 3: Apply out-of-service taints (ONLY after node is confirmed powered off) ---
# These taints signal the CSI driver to release the RWO volume attachment on the dead node.
oc adm taint nodes ${TARGET_NODE} \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
oc adm taint nodes ${TARGET_NODE} \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule

# --- Step 4: Watch workload reschedule on survivor ---
echo "Watching for pod reschedule to ${SURVIVOR_NODE}..."
for i in $(seq 1 18); do
  STATUS=$(oc get pods -A --field-selector spec.nodeName=${SURVIVOR_NODE} \
    --no-headers 2>/dev/null | grep -v "Completed\|Running" | head -3)
  echo "$(date +%H:%M:%S) Non-running pods on survivor: ${STATUS:-none}"
  sleep 10
done

# --- Step 5: Verify data integrity ---
# (exec into rescheduled pod and confirm file content/checksum)

# --- Step 6: Restore node (power on via Pacemaker) ---
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs node unstandby ${TARGET_NODE} || true
# Or use sushy-tools / Redfish to power on the node VM/BMC directly

# --- Step 7: Remove taints after node is Ready ---
oc get nodes -w  # wait for ${TARGET_NODE} to show Ready
oc adm taint nodes ${TARGET_NODE} \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
oc adm taint nodes ${TARGET_NODE} \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule-
```

---

## Alternatives Considered

### Option A — Manual taints only (no Pacemaker fence)
- Works on clusters with 3+ nodes and quorum resilience
- On 2-node TNF: **always causes the CEO etcd-member-removal race** → API outage
- **Rejected**

### Option B — Pacemaker fence + manual taints afterward (CHOSEN)
- Pacemaker uses Redfish STONITH to power off the node — this is authoritative
- CEO sees the node go `NotReady` due to power-off, not taint — CEO behavior is safe
- Taints are applied after power-off to unblock RWO PVC re-attachment
- **Accepted**

### Option C — Simulate with VM power-off (no Pacemaker)
- `sudo virsh destroy openshift-node2` (on KVM host) then apply taints
- Valid for KVM dev environment when Pacemaker STONITH is not yet configured
- Must still apply taints AFTER the VM is powered off, not before
- Not tested as a formal path; document as dev-only alternative

---

## Consequences

**Positive:**
- Eliminates the etcd-operator member-removal race condition
- Demo 5 HA validation can be run repeatably without triggering API outages
- The fencing sequence mirrors production behavior (Pacemaker STONITH is the intended path)

**Negative / Trade-offs:**
- Requires sushy-tools (KVM) or real Redfish BMC to be working for `pcs node fence`
- If Pacemaker STONITH is not configured or times out, the fence step will not proceed
  (this is safe — the cluster remains in its current state rather than entering a race condition)
- Demo 5 cannot be validated with manually-applied taints alone on 2-node TNF

---

## Domain Considerations

- **Why Red Hat article order is unsafe on TNF**: The Red Hat article targets the general ODF
  failover scenario which assumes ≥3 nodes. The 2-node TNF topology is fundamentally different
  because every node is also a control-plane node running etcd. The taint-first order is safe only
  when the API server can survive on the remaining nodes after one node is removed.
- **CEO member-removal is not a bug**: The Cluster Etcd Operator correctly interprets
  `out-of-service` taints as a node departure signal. The unsafe behavior is specific to 2-node
  clusters where departure of any member destroys quorum. This cannot be disabled.
- **Script automation**: `scripts/odf-ha-fence-node.sh` implements this procedure with automated
  preflight checks and enforces the STONITH-before-taints order.

---

## Preflight Checks Before Running Demo 5 Fence Validation

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

echo "=== 1. Kubernetes API responsive ==="
oc get nodes

echo "=== 2. etcd healthy on both nodes ==="
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -A5 "etcd-clone"
# Expected: Started: [openshift-node1 openshift-node2], no Failed Resource Actions

echo "=== 3. etcd port 2379 listening on both nodes ==="
for IP in 192.168.49.21 192.168.49.22; do
  echo -n "$IP: "
  ssh -i $SSH_KEY core@$IP sudo ss -tlnp | grep 2379 | awk '{print $1,$4}' || echo "NOT LISTENING"
done

echo "=== 4. Pacemaker STONITH resource functional ==="
ssh -i $SSH_KEY core@192.168.49.21 \
  sudo pcs stonith status | grep -E "node2_redfish|openshift-node2_redfish"
# Expected: Started openshift-node2 (or similar — not Failed)

echo "=== 5. ODF Ceph cluster healthy ==="
oc get cephcluster -n openshift-storage \
  -o custom-columns="NAME:.metadata.name,HEALTH:.status.ceph.health"
# Expected: HEALTH_OK

echo "=== 6. No existing out-of-service taints ==="
oc get node openshift-node2 -o jsonpath='{.spec.taints}' | python3 -c \
  "import json,sys; t=json.load(sys.stdin); \
   bad=[x for x in (t or []) if 'out-of-service' in x.get('key','')]; \
   print('STALE TAINTS PRESENT:', bad) if bad else print('OK: no out-of-service taints')"
```

If any check fails, **do not proceed with the fence validation**.

---

## ⚠ Incident-Driven Constraint (2026-06-08)

Applying `out-of-service` taints to a live node BEFORE Pacemaker STONITH triggered the CEO to
remove the node from etcd membership, causing `panic: removed all voters` and a complete API
outage. See [004: etcd Outside the Cluster](004-etcd-outside-cluster.md) for the full incident
record and recovery procedure.

**Never apply `out-of-service` taints to a live 2-node TNF cluster node.**

---

## Etcd Recovery Procedure (If Race Condition Is Triggered)

If `out-of-service` taints were applied before Pacemaker fence and the API becomes unresponsive:

```bash
SSH_KEY=~/.ssh/openshift-twonode-ed25519

# 1. Identify which node has clean etcd data (look for exit code 0 in podman ps)
for IP in 192.168.49.21 192.168.49.22; do
  echo "--- $IP ---"
  ssh -i $SSH_KEY core@$IP \
    'sudo podman ps -a --filter "name=etcd" --format "{{.Status}}" 2>&1'
done
# Clean node: "Exited (0) ..." — use this node for recovery

# 2. Wipe corrupt member directory on the OTHER node
ssh -i $SSH_KEY core@<corrupt-node> sudo rm -rf /var/lib/etcd/member

# 3. Set force_new_cluster on the clean node
ssh -i $SSH_KEY core@<clean-node> \
  sudo crm_attribute --lifetime reboot \
    --node <clean-node-hostname> \
    --name force_new_cluster \
    --update <clean-node-hostname>

# 4. Trigger Pacemaker etcd restart
ssh -i $SSH_KEY core@<clean-node> sudo pcs resource cleanup etcd-clone

# 5. Monitor recovery (etcd ~3 min, kube-apiserver reconnects ~2 min after etcd is up)
watch "ssh -i $SSH_KEY core@<clean-node> sudo pcs status | grep etcd"
```

---

## Related ADRs

- [004: etcd Managed Outside the Cluster](004-etcd-outside-cluster.md) — Pacemaker etcd
  architecture; contains the full incident record and recovery commands
- [003: BMC / Redfish Fencing Strategy](003-bmc-redfish-fencing-strategy.md) — Redfish/sushy-tools
  fencing prerequisites; `pcs node fence` depends on a functioning STONITH resource
- [008: ODF TNF Pool Replica Strategy](008-odf-tnf-pool-replica-strategy.md) — StorageCluster
  must be `Ready` before fence validation begins
- [009: ODF TNF Post-Install Tuning](009-odf-tnf-post-install-tuning.md) — resource tuning
  must be complete for ODF to remain stable during HA validation

---

## Related PRD Sections

- Section 5.2: Demo 5 — DRBD Edge Storage (Application support and failover)
- Section 3.2: How TNF Works (Pacemaker STONITH mechanism)

---

## References

- [004: etcd Outside the Cluster](004-etcd-outside-cluster.md)
- [003: BMC / Redfish Fencing Strategy](003-bmc-redfish-fencing-strategy.md)
- [ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)
- `scripts/odf-ha-fence-node.sh` — implements this procedure as a script
- `scripts/tnf-preflight-validate.sh` — comprehensive pre-operation health check
