# 009. ODF TNF Post-Install Tuning — Scope of update-csi-resources.sh

**Status**: Accepted
**Date**: 2026-06-08
**Domain**: storage-architecture / resource-management
**Source**: [Red Hat Customer Portal — ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)

---

## Context

A two-node OpenShift cluster running ODF with 8 vCPUs per node hits a fundamental resource ceiling
during ODF deployment:

| Component | Default CPU Request | Notes |
|---|---|---|
| `rook-ceph-mon` (×3) | 2 CPU each | 6 CPU total across 2 nodes |
| `rook-ceph-mgr` | 2 CPU | |
| `rook-ceph-osd` (×2) | 2 CPU each | Plus 2 CPU per init container |
| CSI ctrlplugin (rbd+cephfs) | 410m each × 2 replicas | |
| OpenShift control plane | ~3–4 CPU per node | kube-apiserver, etcd, etc. |

This saturates both nodes at ~99% CPU **requests**, blocking CSI controller pods (`ctrlplugin`) from
scheduling. The result: `StorageCluster` stays in `Error` because CSI is not available.

The Red Hat article mandates `bash update-csi-resources.sh` as the first post-install step.

---

## Decision

Split the tuning into two layers:

**Layer 1 (declarative — in `storagecluster-drbd.yaml`):**
Embed Ceph daemon resource overrides (`mon`, `mgr`, `osd`, `prepareosd`, `logcollector`,
`crashcollector`, `exporter`) directly in the `StorageCluster` manifest. This is set at deploy time
so pods are never created with the large default requests.

**Layer 2 (script — `scripts/update-csi-resources.sh`):**
Patch the `driver.csi.ceph.io` CRs for RBD and CephFS to reduce CSI controller/node plugin
resource requests. This must be a script because the `driver` CRs are created by the ODF operator
after StorageCluster is applied and cannot be pre-configured in the StorageCluster spec.

---

## Alternatives Considered

### Option A — Single monolithic post-install script
- All patches (Ceph daemon resources + CSI driver resources + pool sizes) in one script
- **Problem:** Ceph daemon requests set via script can be reverted by OCS operator reconcile. Pool
  sizes revert even faster (see 008). Makes the deployment state depend on when the script ran
  relative to the operator's reconcile cycle.

### Option B — Split declarative + script (CHOSEN)
- Ceph daemon resources → `StorageCluster` spec (declarative, survives reconciles)
- CSI driver resources → script (post-install, patches `driver` CRs owned by ODF)
- Pool sizes → separate YAML (see 008)

---

## Consequences

**Positive:**
- Both nodes drop from ~99% to ~85–94% CPU requests after full tuning
- CSI ctrlplugin pods schedule on both nodes
- StorageCluster can reach `Ready`

**Negative / Trade-offs:**
- Reduced CPU limits may cause OSD latency spikes under sustained heavy I/O. Acceptable for
  demo/edge workloads; revisit limits for production-like sizing.
- `update-csi-resources.sh` must be re-run after ODF upgrades (the operator may reset `driver` CR
  resources).

---

## Resource Values (2-Node 8-vCPU Target)

### Ceph daemon requests (in `storagecluster-drbd.yaml`)

| Daemon | CPU Request | Memory Request |
|---|---|---|
| mon | 100m | 512Mi |
| mgr | 100m | 512Mi |
| osd | 100m | 1Gi |
| prepareosd | 50m | 50Mi |
| logcollector | 10m | 50Mi |
| crashcollector | 10m | 60Mi |
| exporter | 10m | 50Mi |

### MDS (CephFilesystem) requests (in `ceph-pools-size2.yaml`)

MDS pods are created by Rook from the `CephFilesystem` CR, not from `StorageCluster.spec.resources`.
The `spec.metadataServer.resources` field must be set explicitly. Rook's MDS pods include an
`chown-container-data-dir` initContainer that inherits the same resource spec.

| Container | CPU Request | Memory Request |
|---|---|---|
| mds (main) | 100m | 512Mi |
| chown-container-data-dir (initContainer) | 50m | 100Mi |
| log-collector | 10m | 50Mi |

### CSI driver requests (via `update-csi-resources.sh`)

| Container | CPU Request |
|---|---|
| plugin (controller) | 100m |
| provisioner / attacher / resizer / snapshotter | 25m each |
| addons / omapGenerator | 50m / 25m |
| logRotator | 10m |
| plugin (node) | 50m |
| registrar | 10m |

### NooBaa (disabled)

NooBaa is not supported in TNF. Setting `spec.multiCloudGateway.reconcileStrategy: ignore` in
`storagecluster-drbd.yaml` prevents the OCS operator from blocking its reconcile loop waiting
for NooBaa to initialize. Without this, the StorageCluster `Degraded` / `Available` conditions
never transition off stale timestamps — the OCS reconcile short-circuits at the NooBaa wait
before reaching the condition-update code path.

---

## Domain Considerations

- **Sizing for non-demo workloads**: The CPU/memory values above are tuned for demo environments
  with 8 vCPUs per node. For production-equivalent workloads, restore OSD CPU to at least 500m
  and monitor `ceph osd perf` for latency.
- **CSI re-patching after upgrades**: The `driver.csi.ceph.io` CRs are owned by the ODF operator.
  After an ODF upgrade, check whether resource requests were reset and re-run
  `scripts/update-csi-resources.sh` if needed.
- **etcd disk sensitivity**: TNF etcd is particularly sensitive to disk I/O. If Ceph OSDs compete
  with etcd for I/O bandwidth, etcd may emit `took too long` warnings. Use separate disks for
  etcd (`/var/lib/etcd`) and OSD data where possible.

---

## Implementation Plan

```bash
# After StorageCluster is in Progressing/Ready state and OSDs are up:
bash scripts/update-csi-resources.sh

# Verify CSI pods are now Running on both nodes:
oc get pods -n openshift-storage | grep ctrlplugin
```

---

## Related ADRs

- [008: ODF TNF Pool Replica Strategy](008-odf-tnf-pool-replica-strategy.md) — pool
  `size=2` configuration; resource tuning is a prerequisite for StorageCluster becoming Ready
- [010: ODF TNF Floating Monitor (mon-c) Image](010-odf-tnf-mon-c-downstream-image.md) —
  image version skew is a separate cause of StorageCluster blockage
- [011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) — HA
  validation that runs after tuning is complete
- [004: etcd Managed Outside the Cluster](004-etcd-outside-cluster.md) — TNF etcd disk I/O
  sensitivity is relevant when sizing OSD resources

---

## Related PRD Sections

- Section 5.2: Demo 5 — DRBD Edge Storage (Post-Installation Tuning step)

---

## References

- [ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)
- `scripts/update-csi-resources.sh`
- `examples/two-node-drbd/storagecluster-drbd.yaml`
