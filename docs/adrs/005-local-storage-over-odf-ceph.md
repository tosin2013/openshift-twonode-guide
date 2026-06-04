# 005. Local Storage (LVM/TopoLVM) as Primary Storage — ODF/Ceph Deferred to Developer Preview

**Status**: Accepted
**Date**: 2026-06-02
**Domain**: storage-architecture / persistent-volumes

## Context

Persistent storage for containerized workloads on OpenShift typically uses one of:

| Option | Replication | Min Nodes | Two-Node Suitability |
|---|---|---|---|
| ODF/Ceph (full) | 3-way replication | 3 (for Ceph OSD quorum) | **Not suitable** — requires a third node |
| ODF + DRBD (Developer Preview) | 2-way DRBD block replication | 2 | Possible, with caveats — see ADR note |
| LVM Operator / TopoLVM | None (local block) | 1 per PVC | Suitable — standard for 2-node edge |
| NFS / external storage | External | External server | Depends on environment |
| hostPath | None | 1 | Development only |

Standard ODF/Ceph requires at minimum 3 OSD nodes to maintain Ceph quorum. On a two-node cluster, ODF cannot achieve quorum without a third node or an arbiter, making it fundamentally incompatible with the TNF topology.

The PRD's Demo 2 (Stateful Database HA) explicitly requires persistent storage for a PostgreSQL workload that survives node failure. The storage layer must:
1. Work on exactly 2 nodes.
2. Support `StatefulSet` / `PersistentVolumeClaim` workloads.
3. Be available for failover after node drain or fencing.

Demo 5 (DRBD Edge Storage) introduces ODF + DRBD as a Developer Preview path. This is explicitly separate from the primary storage architecture to avoid confusion.

## Decision

**Primary storage architecture**: Use the **LVM Operator (TopoLVM)** for local block storage on each node. PVCs are bound to a specific node's local storage and are available to pods scheduled on that node.

This means:
- Stateful workloads (e.g., PostgreSQL in Demo 2) use `StatefulSet` with node-affinity-aware PVCs.
- On node failure, the pod is rescheduled to the surviving node. If the PVC is local to the failed node, the pod cannot start until the node recovers OR the storage is treated as replicated (see DRBD path below).
- Demo 2 addresses this by using node drain (planned failover) as the primary scenario, with hard failure documented as requiring DRBD or external replication for zero-RPO.

**Developer Preview storage path**: Demo 5 documents ODF on Two-Node OpenShift with DRBD (per the Red Hat Developer Preview guide). DRBD replicates a block device across both nodes, enabling a floating PVC accessible from either node. This is a Developer Preview feature as of ODF 4.21 and carries explicit support limitations.

The repository will **not** use ODF/Ceph as the default storage recommendation. All demo READMEs that involve persistent storage will clearly explain this constraint.

## Consequences

**Positive:**
- LVM Operator is simple to deploy and well-understood — no additional operators beyond what TNF requires.
- Local block storage has the best possible I/O performance (no network overhead).
- etcd-on-Podman (see ADR-004) benefits from fast local disk — TNF documentation recommends NVMe/SSD for etcd data directories.
- Clearly documents storage architecture trade-offs, which is educational for the target audience.

**Negative:**
- Local storage PVCs are not inherently HA — if the node hosting the PVC is lost permanently, data on that node is lost.
- Demo 2 (PostgreSQL HA) must be carefully scoped to cover planned failover (drain) for the "full HA" scenario; hard failure with local storage is a data risk if the node does not recover.
- Operators who expect ODF (as they would on a 3+ node cluster) will be surprised by this limitation — must be prominently documented.
- Demo 5 (DRBD) is Developer Preview — it cannot be recommended for production use and its limitations must be explicitly documented.

## Domain Considerations

- **Slow disk latency warnings**: TNF etcd is particularly sensitive to disk I/O latency. The troubleshooting guide must cover the common `etcd is taking too long to fsync` warning and its remediation (SSD/NVMe, I/O priority tuning).
- **Storage class naming**: LVM Operator creates storage classes named after the LVMCluster `deviceClasses`. Templates should use a placeholder storage class name and document how to discover the actual name post-install.
- **Demo 5 caveats**: DRBD with ODF is missing: NooBaa (object storage), NFS, RGW (Rados GW), and Regional DR. The demo README must document these limitations explicitly to avoid production misuse.

## Implementation Plan

1. Deploy LVM Operator in `docs/deployment-guide.md` post-install validation section.
2. In `docs/demos/02-database-ha/`, use a `StorageClass` backed by LVM Operator. Document node-affinity behavior and explain why the pod follows the surviving node on drain.
3. In `docs/demos/02-database-ha/README.md`, include a clear "Storage Architecture Note" section explaining why ODF is not used and what the data-loss risk is for hard failure without replication.
4. In `docs/demos/05-drbd-edge-storage/README.md`, include a prominent "Developer Preview Warning" section listing all unsupported features.
5. Add a disk latency troubleshooting entry in `docs/troubleshooting.md`.

## Related PRD Sections

- Section 5.2: Demo 2 — Stateful Database HA (Storage Note)
- Section 5.2: Demo 5 — DRBD Edge Storage (Developer Preview, Caveats)
- Section 5.1: Troubleshooting Guide (slow disk latency warnings)

## References

- [Deploying ODF on Two-Node OpenShift with Fencing and DRBD — Red Hat Access](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation)
- [LVM Storage Operator documentation](https://docs.openshift.com/container-platform/4.22/storage/persistent_storage/persistent_storage_local/persistent-storage-using-lvms.html)
- [TopoLVM — Kubernetes dynamic volume provisioner for LVM](https://github.com/topolvm/topolvm)
