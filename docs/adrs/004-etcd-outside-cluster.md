# 004. etcd Managed Outside the Cluster via Pacemaker and Podman

**Status**: Accepted
**Date**: 2026-06-02
**Updated**: 2026-06-08 (incident-driven hardening — etcd panic recovery constraint added)
**Domain**: cluster-data-plane / quorum-management

## Context

In a standard OpenShift cluster, etcd runs as a pod managed by the Cluster Etcd Operator (CEO). The CEO ensures etcd member health, handles certificate rotation, and manages quorum. This works well for 3-node (or higher) control planes because a majority quorum can be maintained even when one node is lost.

In a two-node cluster, standard etcd quorum rules mean:
- With 2 etcd members, losing one node loses quorum (1 out of 2 is not a majority).
- The surviving node cannot proceed without quorum — the cluster freezes.
- The CEO cannot recover etcd automatically without a third member.

TNF solves this by removing etcd from the OpenShift pod lifecycle entirely. Instead:
1. etcd runs as a **Podman container** on each node, managed by **Pacemaker** as a cluster resource.
2. Pacemaker monitors etcd health and coordinates its lifecycle across both nodes.
3. When Pacemaker fences a failed node (via STONITH), it knows the failed node's etcd is definitively offline.
4. The surviving node's Pacemaker instance promotes etcd to a **single-member cluster** (force-new-cluster mode).
5. When the fenced node recovers, Pacemaker adds it back as an etcd member and resyncs.

This is fundamentally different from the standard CEO-managed etcd and requires understanding of both Pacemaker resource management and etcd cluster membership operations.

## Decision

Accept the TNF architecture's requirement that **etcd runs outside the OpenShift cluster, managed by Pacemaker as a Podman-based resource**.

This is not a choice — it is an inherent property of the TNF topology. The decision recorded here is to:
1. Clearly document this architectural property so operators understand why standard `oc get etcd` health checks are insufficient.
2. Define the operational model for etcd management in this topology.
3. Identify which monitoring and validation commands apply to this configuration.

The `two-node-toolbox` from the OpenShift project configures this Pacemaker resource setup as part of post-install configuration. This repository will reference and document that toolbox rather than re-implementing the etcd resource configuration from scratch.

## Consequences

**Positive:**
- Enables true two-node HA without a third node or arbiter.
- Pacemaker's STONITH integration provides a coordinated, safe failover — the surviving node only promotes etcd after confirming the failed node is powered off.
- etcd data is preserved on both nodes; the surviving node simply re-establishes quorum with a single-member cluster.
- On recovery, resyncing is automatic via Pacemaker resource management.

**Negative:**
- Operators must know both OpenShift cluster management (`oc`) **and** Pacemaker management (`pcs`) to effectively operate this cluster.
- `oc get clusteroperators` will not reflect etcd status accurately — a dedicated `pcs status` check is required.
- The Cluster Etcd Operator is disabled or works in a degraded mode; some CEO-managed features (automated certificate rotation handling) may behave differently.
- etcd backup and restore procedures differ from standard OpenShift documentation — custom procedures must be documented.
- Split-brain prevention relies entirely on STONITH succeeding. If STONITH fails (BMC unreachable), Pacemaker will not promote etcd on the surviving node, which may appear as a cluster freeze. Operators must understand this safety behavior.

## Domain Considerations

- **Pacemaker resource dependencies**: etcd resource must have a dependency on the STONITH resource completing successfully before promotion. This ordering is critical and must be validated in `pcs config`.
- **etcd data directory**: The etcd data directory on each node persists across fencing events. The deployment guide must document its location and backup procedures.
- **Health validation commands** operators must know:
  - `pcs status` — Pacemaker cluster and resource status
  - `podman ps` — etcd container running status
  - `etcdctl endpoint health` — etcd cluster health from inside the etcd container
  - `oc get clusteroperators` — still useful for OpenShift operator health (excluding etcd-specific status)

## Implementation Plan

1. Document the Pacemaker + etcd architecture clearly in `docs/architecture.md`, with a diagram showing the relationship between Pacemaker, STONITH, etcd-in-Podman, and the OpenShift API server.
2. Reference `two-node-toolbox` for the Pacemaker resource configuration commands in `docs/deployment-guide.md`.
3. Document the full set of health validation commands in `docs/deployment-guide.md` (post-install validation section).
4. Include etcd health validation in the Demo 1 fencing validation scenario — confirm etcd transitions from 2-member to 1-member and back to 2-member.
5. Add a dedicated etcd troubleshooting section in `docs/troubleshooting.md` covering: etcd failing to form quorum, Pacemaker etcd resource failing to start, and STONITH failure leaving the cluster in a frozen state.

## Initial Install Bootstrap Ordering (Critical Constraint)

During initial deployment, the CEO must write `etcd-pod.yaml` and the `etcd-certs` resource directories to **both** nodes via installer pods. This requires the kube-apiserver to be accessible. However:

- Node2's etcd starts in 2-member `ETCD_INITIAL_CLUSTER_STATE=existing` mode immediately after bootstrap-complete.
- Without node1's etcd, node2's 2-member Raft cluster has no quorum (2 members, 1 required for majority = 2, not met).
- Node2's kube-apiserver cannot start because etcd is unresponsive.
- The CEO cannot run installer pods without the kube-apiserver.

**Recovery technique** (automated in Phase 8.5 of `scripts/deploy-tnf-kvm.sh`):
```
# Inject --force-new-cluster into /etc/kubernetes/manifests/etcd-pod.yaml on node2
# Kubelet restarts etcd as single-member with quorum → KAS starts → CEO installs node1
```

**Manual etcdctl exec syntax for OCP 4.22 (etcd v3.6)**:
```bash
ETCD_CTR=$(sudo crictl ps --name '^etcd$' -q | head -1)
sudo crictl exec ${ETCD_CTR} sh -c '
  unset ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY
  etcdctl \
    --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node2.crt \
    --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node2.key \
    --endpoints=https://localhost:2379 \
    member list -w table'
```
Note: all `ETCDCTL_*` env vars must be unset before passing flags — etcd v3.6 enforces no-conflict between env vars and CLI flags.

## ⚠ Incident-Driven Constraint (Added 2026-06-08 — Hardening)

**Incident**: Applying `node.kubernetes.io/out-of-service=nodeshutdown` taints to a live node via
`oc adm taint` (without prior Pacemaker STONITH) caused the Cluster Etcd Operator (CEO) to
interpret the taint as a fence event and **remove the tainted node from the etcd member list**.
In a 2-node cluster, this leaves 0 voters → `panic: removed all voters` on the tainted node's
etcd → the surviving node cannot form quorum → kube-apiserver unresponsive.

**Root violation**: The ADR assumption "Pacemaker STONITH provides coordinated failover" was
bypassed. The CEO is a Kubernetes workload that also monitors node state and can remove etcd
members independently of Pacemaker — it does not check whether the node was fenced via STONITH
before acting.

**Constraints added**:
1. **Never apply `out-of-service` taints before Pacemaker has confirmed the node is powered off.**
   The correct order is: `pcs node fence <node>` → confirm fenced (node NotReady) → apply taints.
2. **`out-of-service` taints are for RWO PVC failover signaling, not for fencing.** They must
   only be applied to nodes that are already powered off via STONITH.
3. **Demo 5 validation must use `pcs node fence` (Redfish/IPMI), not manual taints**, to avoid
   triggering the CEO member-removal race condition.

**Recovery procedure** (if etcd panics due to `removed all voters`):
```bash
# Step 1: Wipe corrupt member directory on the panicked node
ssh core@<panic-node> sudo rm -rf /var/lib/etcd/member

# Step 2: Set force_new_cluster attribute on the node with clean WAL data
ssh core@<clean-node> sudo crm_attribute --lifetime reboot \
  --node <clean-node-hostname> --name force_new_cluster \
  --update <clean-node-hostname>

# Step 3: Trigger Pacemaker to restart etcd
ssh core@<clean-node> sudo pcs resource cleanup etcd-clone

# Step 4: Wait for etcd (~3 min) then kube-apiserver (~2 min)
watch "ssh core@<clean-node> sudo pcs status | grep etcd"
```

## Related ADRs

- [001: TNF Topology Selection](001-tnf-topology-selection.md) — TNF topology decision that
  mandates Pacemaker-managed etcd; includes the incident-driven constraint update
- [003: BMC / Redfish Fencing Strategy](003-bmc-redfish-fencing-strategy.md) — Pacemaker STONITH
  prerequisite; etcd promotion only occurs after STONITH confirms node power-off
- [011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) — the
  correct STONITH-before-taints sequence for HA validation; references this ADR's recovery commands

---

## Related PRD Sections

- Section 3.2: How TNF Works
- Section 5.1: Troubleshooting Guide (etcd failing to form quorum)
- Section 5.2: Demo 1 — Fencing Validation (observe Pacemaker fence and etcd single-member restart)

## References

- [Two-Node with Fencing — two-node-toolbox](https://github.com/openshift/two-node-toolbox)
- [Pacemaker Resource Agents documentation](https://clusterlabs.org/pacemaker/doc/)
- [etcd documentation: Disaster recovery — restoring a cluster](https://etcd.io/docs/v3.5/op-guide/recovery/)
