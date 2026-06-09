# 008. ODF TNF Pool Replica Strategy — reconcileStrategy=ignore with size=2

**Status**: Accepted
**Date**: 2026-06-08
**Domain**: storage-architecture / odf-configuration
**Source**: [Red Hat Customer Portal — ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)

---

## Context

Two-Node OpenShift (TNF) ODF 4.21 Developer Preview has exactly **2 OSDs** (one per node). The OCS
operator defaults to creating `CephBlockPool` and `CephFilesystem` with `replicated.size=3`, which
assumes a 3-node cluster.

With only 2 OSDs, a `size=3` pool produces:
- `PG_DEGRADED HEALTH_WARN` in Ceph (33% of objects undersized)
- OCS operator reads `HEALTH_WARN` → sets `Degraded=True` on `StorageCluster`
- `StorageCluster` stays in `Phase: Error` indefinitely

The OCS operator also uses `reconcileStrategy: manage` by default, meaning it **reverts any direct
patches** to `CephBlockPool` and `CephFilesystem` back to `size=3` every reconcile cycle (~30–60
seconds). This makes manual post-deploy patching fragile and non-durable.

---

## Decision

Set `reconcileStrategy: ignore` for `cephBlockPools` and `cephFilesystems` in the `StorageCluster`
manifest, and ship separate `CephBlockPool` / `CephFilesystem` manifests with
`replicated.size=2, requireSafeReplicaSize: false`.

**Chosen option:** Option B — `reconcileStrategy: ignore` + `ceph-pools-size2.yaml`

---

## Alternatives Considered

### Option A — `reconcileStrategy: manage` + post-install script patch
- `storagecluster-drbd.yaml` keeps `manage` (default)
- A post-install script patches pool sizes after StorageCluster creation
- **Problem:** OCS reconcile loop reverts patches within 30–60 seconds. Pool stays at `size=3`.
  `StorageCluster` never leaves `Error`. This was validated during deployment (observed 3 reversion
  cycles).

### Option B — `reconcileStrategy: ignore` + explicit pool manifests (CHOSEN)
- `storagecluster-drbd.yaml` sets `reconcileStrategy: ignore` for `cephBlockPools` and
  `cephFilesystems`
- `examples/two-node-drbd/ceph-pools-size2.yaml` declares both CRs with `size=2`
- OCS stops managing these resources; Rook applies the pool CRs directly
- Patches are durable across OCS operator restarts and reconcile cycles

---

## Consequences

**Positive:**
- `CephBlockPool` pool stays at `size=2` → `HEALTH_OK` → `StorageCluster` reaches `Ready`
- Pools are declared as code; deployment is repeatable

**Negative / Trade-offs:**
- OCS will not auto-update `CephBlockPool` or `CephFilesystem` if the ODF operator updates its
  defaults (e.g., after a minor upgrade). Review on ODF upgrades.
- `requireSafeReplicaSize: false` suppresses Rook's safety check — acceptable for a 2-node HA
  deployment where `size=2` is the correct design choice, not a degraded state.
- CephFilesystem MDS configuration must also be explicitly set in `ceph-pools-size2.yaml`.

---

## Domain Considerations

- **ODF upgrade behavior**: After any ODF operator upgrade, verify that `reconcileStrategy: ignore`
  is preserved in the StorageCluster spec. If the operator forcibly re-enables `manage`, the pools
  will revert to `size=3` at the next reconcile and the cluster will show `HEALTH_WARN` again.
- **MDS resource sizing**: Pool size configuration is not the only scheduling concern. MDS pods
  created by the `CephFilesystem` CR use default resource requests unless
  `spec.metadataServer.resources` is set explicitly — see 009 for the full resource tuning
  approach.
- **Pool recreation**: If the `CephBlockPool` or `CephFilesystem` CRs are deleted while
  `reconcileStrategy: ignore` is set, they will not be re-created by the OCS operator. Re-apply
  from `ceph-pools-size2.yaml`.

---

## Implementation Plan

```bash
# 1. Apply StorageCluster (includes reconcileStrategy=ignore and resource overrides)
oc apply -f examples/two-node-drbd/storagecluster-drbd.yaml

# 2. Wait for OSDs to be Running
oc get pods -n openshift-storage | grep osd

# 3. Apply pool size manifests
oc apply -f examples/two-node-drbd/ceph-pools-size2.yaml
```

---

## Related ADRs

- [009: ODF TNF Post-Install Tuning](009-odf-tnf-post-install-tuning.md) — resource sizing
  for Ceph daemons and CSI; complements pool configuration
- [010: ODF TNF Floating Monitor (mon-c) Image](010-odf-tnf-mon-c-downstream-image.md) —
  mon-c image must match OCS-managed mons for Rook to reconcile `CephFilesystem`
- [011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) — safe
  HA validation that depends on a healthy StorageCluster
- [005: Local Storage as Primary Storage](005-local-storage-over-odf-ceph.md) — overall storage
  architecture decision that contextualizes ODF/DRBD as Developer Preview

---

## Related PRD Sections

- Section 5.2: Demo 5 — DRBD Edge Storage (Developer Preview, Caveats)

---

## References

- [ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)
- `examples/two-node-drbd/storagecluster-drbd.yaml`
- `examples/two-node-drbd/ceph-pools-size2.yaml`
