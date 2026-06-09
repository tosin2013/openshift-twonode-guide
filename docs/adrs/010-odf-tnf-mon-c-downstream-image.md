# 010. ODF TNF Floating Monitor (mon-c) — Use Downstream Ceph Image

**Status**: Accepted
**Date**: 2026-06-08
**Domain**: storage-architecture / container-image-management
**Source**: [Red Hat Customer Portal — ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)

---

## Context

The floating Ceph monitor (`mon-c`) is deployed manually via `scripts/mon-deployment.sh` using
the `CEPH_IMAGE` environment variable. The Red Hat article explicitly states:

> "Edit `mon-deployment.sh` to change the Ceph image to the **downstream image**."

The ODF operator deploys `mon-a` and `mon-b` from the same production image it uses for all
managed Ceph daemons:

```
registry.redhat.io/rhceph/rhceph-9-rhel9@sha256:ad4a6277...
```

When `mon-deployment.sh` uses a dev/CI image (`quay.io/rhceph-ci/rhceph:v9.0-...`), the result
is a **Ceph version skew** between monitors:

| Monitor | Image | Ceph Version |
|---------|-------|-------------|
| mon-a | `registry.redhat.io/rhceph/rhceph-9-rhel9@sha256:ad4a…` | 20.1.0-185 |
| mon-b | same production image | 20.1.0-185 |
| mon-c | `quay.io/rhceph-ci/rhceph:v9.0-6f8bce9…` | 20.1.0-159 |

Rook detects this mismatch and **refuses to reconcile `CephFilesystem`** until all monitors run
the same version. Error seen in Rook operator logs:

```
file-controller: [openshift-storage/ocs-storagecluster-cephfilesystem] failed to reconcile
waiting for ceph monitors upgrade to finish.
current version: 20.1.0-159 tentacle.
expected version: 20.1.0-185 tentacle.
will reconcile again in 1m0s
```

This blocks MDS pod creation, keeps `CephFilesystem` in `Progressing`, and causes
`HEALTH_ERR: 1 filesystem is offline`.

---

## Decision

The `CEPH_IMAGE` variable in `scripts/mon-deployment.sh` **must always match the production
downstream image used by the ODF operator**. Set it to the SHA-pinned digest of
`registry.redhat.io/rhceph/rhceph-9-rhel9`.

The `DRBD_UTILS_IMAGE` remains separate (`quay.io/rhceph-dev/odf4-drbd-rhel9:v4.21.0-1`) and
must NOT be replaced with the Ceph image.

---

## Alternatives Considered

### Option A — Use dev/CI image (quay.io/rhceph-ci) for mon-c
- Simpler to pull (no Red Hat registry authentication required)
- **Problem:** Creates a version skew between mon-c and ODF-managed mon-a/b. Rook blocks
  `CephFilesystem` reconciliation indefinitely. MDS pods never start. This was observed in
  production during Demo 5 deployment and caused an extended blockage.

### Option B — Use production downstream image SHA-pinned (CHOSEN)
- Guarantees mon-c runs the same Ceph version as mon-a/b
- Requires Red Hat registry credentials on the deployment host
- SHA pin ensures reproducibility across deployments

---

## Consequences

**Positive:**
- All three mons on the same Ceph version → Rook reconciles `CephFilesystem` → MDS pods start
- `CephFilesystem` reaches `Ready` → `HEALTH_OK` → `StorageCluster` reaches `Ready`

**Negative / Trade-offs:**
- The `CEPH_IMAGE` digest in `mon-deployment.sh` must be updated when the ODF operator
  upgrades its Ceph image. Check the image used by `rook-ceph-mon-a` after any ODF upgrade
  and update `mon-deployment.sh` accordingly.

---

## Container Image Mapping

The mon-c deployment has two distinct image roles:

| Container | Role | Image |
|-----------|------|-------|
| `mon` (main) | Ceph daemon | `CEPH_IMAGE` (downstream) |
| `log-collector` | Ceph log sidecar | `CEPH_IMAGE` (downstream) |
| `init-mon-fs` (initContainer) | Ceph mon init | `CEPH_IMAGE` (downstream) |
| `chown-container-data-dir` (initContainer) | Ceph permission fix | `CEPH_IMAGE` (downstream) |
| `shut-down-app` (main) | DRBD secondary-on-shutdown | `DRBD_UTILS_IMAGE` |
| `drbd-init` (initContainer) | DRBD promote to primary | `DRBD_UTILS_IMAGE` |

Setting `CEPH_IMAGE` to the DRBD utils image (or vice versa) causes the mon to fail to start.

---

## Domain Considerations

- **Image pinning vs. floating tags**: Always use a SHA digest (`@sha256:...`) rather than a
  floating tag (e.g., `:latest`) for `CEPH_IMAGE`. Floating tags can silently change during
  a redeployment, causing unexpected version skew.
- **Red Hat registry authentication**: The `registry.redhat.io` image requires a pull secret
  with valid Red Hat subscription credentials. Verify the pull secret is present in
  `openshift-storage` namespace before deploying mon-c:
  ```bash
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | \
    base64 -d | python3 -m json.tool | grep registry.redhat.io
  ```
- **Image discovery after upgrade**: Run the following to get the current production Ceph image
  SHA after any ODF operator upgrade:
  ```bash
  oc get pod -n openshift-storage -l app=rook-ceph-mon \
    -o jsonpath='{.items[0].spec.containers[0].image}'
  ```

---

## Implementation Plan

Update `scripts/mon-deployment.sh`:

```bash
# Production downstream Ceph image — matches what the ODF operator deploys for mon-a/mon-b.
# Using the dev image (quay.io/rhceph-ci) causes a version mismatch that blocks
# Rook from reconciling CephFilesystem.
export CEPH_IMAGE=registry.redhat.io/rhceph/rhceph-9-rhel9@sha256:<current-digest>
export DRBD_UTILS_IMAGE=quay.io/rhceph-dev/odf4-drbd-rhel9:v4.21.0-1
```

---

## Related ADRs

- [008: ODF TNF Pool Replica Strategy](008-odf-tnf-pool-replica-strategy.md) — pool
  `size=2` is a prerequisite for `CephFilesystem` to report `HEALTH_OK` once MDS starts
- [009: ODF TNF Post-Install Tuning](009-odf-tnf-post-install-tuning.md) — resource
  sizing ensures MDS pods have CPU/memory headroom to schedule after mon-c is healthy
- [011: ODF TNF Demo 5 Fencing Procedure](011-odf-tnf-demo5-fencing-procedure.md) — HA
  validation depends on a fully healthy StorageCluster, which requires mon-c using the correct image

---

## Related PRD Sections

- Section 5.2: Demo 5 — DRBD Edge Storage (Floating monitor deployment step)

---

## References

- [ODF 4.21 TNF Developer Preview](https://access.redhat.com/articles/7139231)
- `scripts/mon-deployment.sh`
- `examples/two-node-drbd/ceph-pools-size2.yaml`
