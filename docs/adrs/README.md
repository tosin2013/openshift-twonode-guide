# Architectural Decision Records (ADRs)

This directory contains all Architectural Decision Records for the `openshift-twonode-guide`
project. ADRs document significant technical decisions, their context, the alternatives considered,
and the rationale for the chosen approach.

## Numbering Scheme

ADRs 001–007 cover **architecture-wide decisions** that apply to the entire two-node TNF cluster.
ADRs 008–011 cover **ODF-specific decisions** (Demo 5 — DRBD Edge Storage Developer Preview).

---

## Index

### Architecture-Wide ADRs

| # | File | Domain | Status | Summary |
|---|------|--------|--------|---------|
| 001 | [001-tnf-topology-selection.md](001-tnf-topology-selection.md) | cluster-topology / high-availability | Accepted | Choose TNF (Two-Node with Fencing) over TNA; Pacemaker + STONITH provides 2-node HA without an arbiter |
| 002 | [002-agent-based-installer.md](002-agent-based-installer.md) | deployment-automation / installer-strategy | Accepted | Use Agent-Based Installer (ABI) via `openshift-agent-install` framework; documents the TNF bootstrap ordering deadlock and its automated fix |
| 003 | [003-bmc-redfish-fencing-strategy.md](003-bmc-redfish-fencing-strategy.md) | high-availability / fencing | Accepted | Use `fence_redfish` for Pacemaker STONITH in both bare-metal (real BMC) and KVM (sushy-tools) environments |
| 004 | [004-etcd-outside-cluster.md](004-etcd-outside-cluster.md) | cluster-data-plane / quorum-management | Accepted | Accept TNF's requirement that etcd runs outside OpenShift, managed by Pacemaker + Podman; includes incident-driven constraint from the 2026-06-08 etcd panic recovery |
| 005 | [005-local-storage-over-odf-ceph.md](005-local-storage-over-odf-ceph.md) | storage-architecture / persistent-volumes | Accepted | LVM Operator (TopoLVM) as primary storage for 2-node clusters; ODF + DRBD documented as Demo 5 Developer Preview |
| 006 | [006-ovnkubernetes-network-plugin.md](006-ovnkubernetes-network-plugin.md) | network-architecture / cni-plugin | Accepted | OVNKubernetes is a hard TNF requirement and the only supported CNI plugin for this topology |
| 007 | [007-kvm-sushy-tools-dev-environment.md](007-kvm-sushy-tools-dev-environment.md) | development-environment / testing-infrastructure | Accepted | KVM + sushy-tools as the development environment; replaces the rejected nested KubeVirt + fakefish approach |

### ODF-Specific ADRs (Demo 5 — DRBD Edge Storage)

| # | File | Domain | Status | Summary |
|---|------|--------|--------|---------|
| 008 | [008-odf-tnf-pool-replica-strategy.md](008-odf-tnf-pool-replica-strategy.md) | storage-architecture / odf-configuration | Accepted | Set `reconcileStrategy: ignore` for Ceph pools + explicit `ceph-pools-size2.yaml` to prevent OCS operator reverting `size=2` back to `size=3` |
| 009 | [009-odf-tnf-post-install-tuning.md](009-odf-tnf-post-install-tuning.md) | storage-architecture / resource-management | Accepted | Split ODF resource tuning: declarative Ceph daemon overrides in `StorageCluster` + script-based CSI driver patching; NooBaa disabled via `reconcileStrategy: ignore` |
| 010 | [010-odf-tnf-mon-c-downstream-image.md](010-odf-tnf-mon-c-downstream-image.md) | storage-architecture / container-image-management | Accepted | Floating monitor (mon-c) must use the same SHA-pinned production Ceph image as ODF-managed mon-a/b to prevent Rook from blocking `CephFilesystem` reconciliation |
| 011 | [011-odf-tnf-demo5-fencing-procedure.md](011-odf-tnf-demo5-fencing-procedure.md) | high-availability / fencing / odf-validation | Accepted | Pacemaker STONITH must precede `out-of-service` taints on 2-node TNF; taints-first causes the CEO to remove the etcd member, dropping quorum to 0 and crashing the API server |

---

## Key Cross-Cutting Dependencies

```
001 (TNF topology)
 ├── depends on → 003 (BMC fencing)
 ├── depends on → 004 (etcd outside cluster)
 ├── depends on → 006 (OVNKubernetes)
 └── developed via → 007 (KVM dev env)

002 (ABI installer)
 ├── deploys → 001 (TNF topology)
 └── uses → 003/007 for BMC/KVM configuration

004 (etcd outside cluster)  ← ⚠ INCIDENT-DRIVEN UPDATE 2026-06-08
 └── governs → 011 (fencing procedure)

005 (local storage primary)
 └── references Developer Preview path → 008, 009, 010, 011

011 (Demo 5 fencing procedure)  ← ⚠ INCIDENT-DRIVEN NEW ADR 2026-06-08
 ├── requires → 003 (working STONITH)
 ├── requires → 008 + 009 + 010 (healthy StorageCluster)
 └── documents → etcd panic recovery (see also 004)
```

---

## Template

All ADRs in this directory follow this structure:

```markdown
# NNN. Title

**Status**: Accepted | Superseded | Deprecated
**Date**: YYYY-MM-DD
**Updated**: YYYY-MM-DD (reason)          # only when applicable
**Domain**: domain-area / sub-area

## Context
## Decision
## Alternatives Considered
## Consequences
## Domain Considerations
## Implementation Plan
## ⚠ Incident-Driven Constraints         # only when applicable
## Related ADRs
## Related PRD Sections
## References
```

---

## Incident History

| Date | ADRs Affected | Description |
|------|---------------|-------------|
| 2026-06-08 | 004 (updated), 011 (created) | etcd `panic: removed all voters` — applying `out-of-service` taints to a live 2-node TNF node before Pacemaker STONITH caused the CEO to remove the node from etcd membership, dropping quorum to 0 and making the kube-apiserver unresponsive for ~1.5 hours |

See `docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md` for the full incident report.
