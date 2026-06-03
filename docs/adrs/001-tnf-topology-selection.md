# 001. Two-Node with Fencing (TNF) Topology Selection

**Status**: Accepted
**Date**: 2026-06-02
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

## Related PRD Sections

- Section 3.1: Two Distinct Two-Node Topologies
- Section 3.2: How TNF Works
- Section 5.1: Phase 1 — Deployment (Configuration Templates)
- Section 7: Success Criteria

## References

- [Two-Node with Fencing — two-node-toolbox](https://github.com/openshift/two-node-toolbox)
- [Architectural Paradigms: TNA vs TNF Deep Dive — Tosin Akinosho, Medium](https://medium.com/@takinosh)
- OpenShift 4.22 Release Notes — Two-Node Topologies
