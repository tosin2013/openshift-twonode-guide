# 001. Two-Node with Fencing (TNF) Topology Selection

**Status**: Accepted
**Date**: 2026-06-02
**Updated**: 2026-06-08 (incident-driven hardening — etcd taint race condition documented)
**Domain**: cluster-topology / high-availability

## Context

OpenShift 4.20+ introduced two distinct two-node topologies that are architecturally incompatible:

| Feature | Two-Node with Fencing (TNF) | Two-Node with Arbiter (TNA) |
|---|---|---|
| Total Physical Nodes | 2 | 3 (2 full + 1 micro arbiter) |
| Quorum Mechanism | Pacemaker + BMC STONITH | Standard etcd (3 members) |
| etcd Management | Pacemaker via Podman, outside cluster | Standard Cluster Etcd Operator |
| Hardware Requirement | Bare metal with Redfish/IPMI BMC | Virtual or physical |
| GA Status (4.20/4.21) | Technology Preview | Generally Available |
| Upgrade Path | Requires reinstallation (`featureSet: TechPreviewNoUpgrade`) | Standard OCP upgrade path |

The project goal is to replace Module 3 of the `retail-edge-ha-workshop`, which originally attempted to demonstrate a **two-physical-server** edge deployment. The site constraint is an absolute hard limit of two physical servers — no third arbiter node is available.

The original Module 3 used nested KubeVirt VMs with fakefish-kubevirt as a Redfish emulator, which failed due to: MAC address regeneration on restart breaking ABI network config, nested virtualization performance degradation, and UDN reachability issues preventing `openshift-install agent wait-for install-complete`.

## Alternatives Considered

### Option A — Two-Node with Arbiter (TNA)
- Requires a third micro-arbiter node to maintain standard 3-member etcd quorum
- GA-supported in OCP 4.20+; standard upgrade path available
- **Problem:** The target site constraint is an absolute hard limit of two physical servers — no
  third node is available. TNA is also not the most extreme edge case to demonstrate.

### Option B — Two-Node with Fencing (CHOSEN)
- Exactly 2 physical nodes; Pacemaker + STONITH provides HA without a third quorum member
- Directly addresses the two-server constraint and replaces the broken Module 3 scenario
- Technology Preview in OCP 4.20/4.21/4.22 — requires `featureSet: TechPreviewNoUpgrade`

### Option C — Single-node OpenShift (SNO)
- Single node with no HA; simplest deployment
- **Problem:** Does not demonstrate HA failover, which is the core learning objective

---

## Decision

This repository targets **TNF (Two-Node with Fencing)** exclusively for the primary deployment path.

TNF uses Pacemaker and Corosync to manage etcd as a Podman container outside the OpenShift pod lifecycle. When a node becomes unresponsive, Pacemaker issues a STONITH (Shoot The Other Node In The Head) command via the node's BMC using the Redfish protocol. This guarantees the failed node cannot write stale data, preventing split-brain. The surviving node restarts etcd as a single-member cluster; the fenced node resyncs on recovery.

TNA will be documented as a future enhancement (`examples/two-node-arbiter/`) for users who require the GA-supported production path but is not the primary focus of this repository.

## Consequences

**Positive:**
- Absolutely minimal hardware footprint — exactly 2 physical servers required.
- Direct, hardware-backed replacement for the broken Module 3 scenario.
- Demonstrates the most extreme edge deployment case (remote sites with only 2 servers).
- Pacemaker/STONITH is a battle-tested HA mechanism from Linux high-availability stacks.

**Negative:**
- TNF is Technology Preview as of OCP 4.20/4.21/4.22; upgrades require reinstallation.
- Requires physical BMC (Redfish/IPMI) on each node — not available in all environments.
- Higher operational complexity than TNA: Pacemaker and Corosync must be understood separately from OpenShift cluster operators.
- `featureSet: TechPreviewNoUpgrade` must be set in the install-config, preventing use of other Tech Preview features alongside TNF.

## Domain Considerations

- The fencing mechanism (STONITH via Redfish) is a hard dependency; this topology cannot work without proper BMC access. All configuration templates must validate BMC reachability before ISO generation.
- etcd running outside the cluster means standard `oc` cluster health checks are insufficient — operators must also check `pcs status` on the nodes directly.
- For development/testing without physical BMC, `sushy-tools` on KVM provides equivalent Redfish semantics (see ADR-007).

## Implementation Plan

1. Set `featureSet: TechPreviewNoUpgrade` in cluster configuration YAML.
2. Set `platform_type: baremetal`, `control_plane_replicas: 2`, `app_node_replicas: 0`.
3. Document TNF vs TNA distinction in `docs/architecture.md` as the primary architectural decision.
4. Provide `examples/two-node-fencing/` templates as the canonical deployment path.
5. Reference TNA as a future enhancement in `docs/architecture.md`.

## ⚠ Incident-Driven Constraint (Added 2026-06-08 — Hardening)

**Incident**: During Demo 5 HA validation, applying `node.kubernetes.io/out-of-service` taints to
a live node (before Pacemaker STONITH) caused the Cluster Etcd Operator (CEO) to remove that node
from the etcd member list. In a 2-node cluster, this leaves 0 voters, triggering
`panic: removed all voters` on the tainted node's etcd and making the kube-apiserver unresponsive.

**Violated assumption**: The ADR description "The surviving node's Pacemaker instance promotes etcd
to a single-member cluster" implies Pacemaker is the only actor that modifies etcd membership. The
CEO is a second actor that can independently remove etcd members in response to Kubernetes node
state changes — it does not coordinate with Pacemaker.

**Constraint**: On 2-node TNF clusters, `out-of-service` taints must **only** be applied to nodes
that have already been powered off via Pacemaker STONITH. Never apply taints to a live node first.

See [004: etcd Outside the Cluster](004-etcd-outside-cluster.md) for the full incident record and
[011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) for the
correct safe fencing sequence.

---

## Related ADRs

- [002: Agent-Based Installer](002-agent-based-installer.md) — deployment method for TNF clusters
- [003: BMC / Redfish Fencing Strategy](003-bmc-redfish-fencing-strategy.md) — Pacemaker STONITH
  implementation; TNF cannot function without BMC access
- [004: etcd Managed Outside the Cluster](004-etcd-outside-cluster.md) — etcd operational model
  specific to TNF; standard `oc` health checks are insufficient
- [005: Local Storage as Primary Storage](005-local-storage-over-odf-ceph.md) — storage architecture
  for 2-node clusters; ODF/DRBD is a Developer Preview path
- [006: OVNKubernetes Network Plugin](006-ovnkubernetes-network-plugin.md) — required CNI for TNF
- [007: KVM + sushy-tools Dev Environment](007-kvm-sushy-tools-dev-environment.md) — development
  environment that simulates TNF without physical hardware
- [011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) — safe
  STONITH-first fencing sequence for ODF HA validation

---

## Related PRD Sections

- Section 3.1: Two Distinct Two-Node Topologies
- Section 3.2: How TNF Works
- Section 5.1: Phase 1 — Deployment (Configuration Templates)
- Section 7: Success Criteria

## References

- [Two-Node with Fencing — two-node-toolbox](https://github.com/openshift/two-node-toolbox)
- [Architectural Paradigms: TNA vs TNF Deep Dive — Tosin Akinosho, Medium](https://medium.com/@takinosh)
- OpenShift 4.22 Release Notes — Two-Node Topologies
