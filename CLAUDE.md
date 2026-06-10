# CLAUDE.md — AI Agent Guidance for openshift-twonode-guide

This file provides persistent guidance for AI coding agents (Claude, Cursor, etc.)
working in this repository. Rules here override default agent behavior.

---

## Repository Context

This repository documents and implements a **Two-Node OpenShift (TNF) demo guide** covering
five demos: Fencing Validation, Database HA, Virtualization HA, Edge AI, and ODF DRBD storage.

Key architectural facts:
- Both nodes run control-plane (kube-apiserver, etcd via Pacemaker)
- etcd is managed by **Pacemaker** (not the standard CEO), as a `podman-etcd` OCF resource
- Fencing uses Redfish/IPMI via `fence_redfish` STONITH in Pacemaker
- ODF 4.21 with DRBD is a **Developer Preview** feature
- The Kubernetes API VIP (192.168.49.253) floats between nodes via keepalived

Before any non-trivial coding task in this repo, recall:
```
pmb recall "TNF etcd conventions lessons"
pmb recall "ODF TNF known issues"
```

---

## Known Failure Patterns — v4.21

### [CRITICAL] Manual `out-of-service` taints on live 2-node TNF node → API outage

**Symptom pattern**: `oc` commands time out with `context deadline exceeded` after applying
`node.kubernetes.io/out-of-service=nodeshutdown` taints to a live (powered-on) node on a
2-node TNF cluster.

**Always verify** that Pacemaker has confirmed the node is powered off (`pcs node fence` 
completed, node shows `NotReady`) **before** applying `out-of-service` taints.

**Root cause**: The Cluster Etcd Operator (CEO) reacts to `out-of-service` taints by removing
the tainted node from the etcd member list. On a 2-node cluster, removing one voter leaves
0 voters → `panic: removed all voters` on the tainted node's etcd → surviving node cannot
form quorum → kube-apiserver hangs.

**Correct fencing order for Demo 5 / any HA validation on 2-node TNF**:
1. Pre-flight: verify `pcs status` shows etcd Started on both nodes, port 2379 listening
2. Fence via Pacemaker: `pcs node fence <node>` (uses Redfish/IPMI)
3. Wait for node to go `NotReady` in Kubernetes
4. Only then apply `out-of-service` taints

**Recovery** (if triggered — API is down):
```bash
# Wipe corrupt node's member dir, set force_new_cluster, cleanup Pacemaker
bash scripts/etcd-pacemaker-recovery.sh \
  --clean-node openshift-node1 --clean-node-ip 192.168.49.21 \
  --corrupt-node openshift-node2 --corrupt-node-ip 192.168.49.22
```

See: `docs/adrs/011-odf-tnf-demo5-fencing-procedure.md`, PMB tag: `hardening, v4.21`

---

### [CRITICAL] etcd health cannot be checked with `oc get clusteroperators` on TNF

**Symptom pattern**: `oc get clusteroperators` shows etcd operator as `Available` even when
etcd is not running.

**Always verify** etcd health via Pacemaker on 2-node TNF, not via `oc`:
```bash
ssh core@192.168.49.21 sudo pcs status | grep -A5 "etcd-clone"
ssh core@192.168.49.21 sudo ss -tlnp | grep 2379
```

**Root cause**: etcd in TNF runs as a Pacemaker-managed Podman container, not as a
kube-apiserver-managed static pod. `oc get clusteroperators` reflects the operator's view,
not the actual etcd process state.

See: `docs/adrs/004-etcd-outside-cluster.md`

---

### [HIGH] ODF StorageCluster stays in Error with `PG_DEGRADED` on 2-node

**Symptom**: `StorageCluster` stays in `Phase: Error`, Ceph shows `HEALTH_WARN PG_DEGRADED`.

**Always verify** that `CephBlockPool` and `CephFilesystem` are using `replicated.size=2`,
not the default `size=3`. Apply `examples/two-node-drbd/ceph-pools-size2.yaml` and ensure
`storagecluster-drbd.yaml` has `reconcileStrategy: ignore`.

See: `docs/adrs/008-odf-tnf-pool-replica-strategy.md`

---

### [HIGH] Floating monitor (mon-c) version skew blocks CephFilesystem

**Symptom**: `CephFilesystem` stays in `Progressing`, Rook logs show version mismatch
(`current: 20.1.0-159 tentacle, expected: 20.1.0-185`).

**Always verify** that `CEPH_IMAGE` in `scripts/mon-deployment.sh` matches the image used
by `rook-ceph-mon-a` and `rook-ceph-mon-b`. Use the downstream production image, not the
`quay.io/rhceph-ci` dev image.

```bash
# Get the correct image from a running ODF-managed mon:
oc get pod -n openshift-storage -l app=rook-ceph-mon \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

See: `docs/adrs/010-odf-tnf-mon-c-downstream-image.md`

### [WARNING] ODF CSI resource starvation → ODF pods stuck Pending after deployment

**Symptom pattern**: After ODF deployment, `rook-ceph-mon-a`, `rook-ceph-osd-1`, and
`rook-ceph-mds-a` are stuck `Pending`. `StorageCluster` phase shows `Error`. `CephCluster`
may still report `HEALTH_OK`. Node1 is at ≥90% CPU requests.

**Always verify** two things after running `update-csi-resources.sh`:
1. Delete stale `Error`/`CrashLoopBackOff` CSI pods — they retain pre-patch CPU reservations
2. Confirm pod count (not just `HEALTH_OK`) — run with `--odf` flag: `bash scripts/tnf-preflight-validate.sh --odf`

**Root cause**: Default ODF CSI controller pods request far more CPU than available on a
2-node KVM cluster. The `update-csi-resources.sh` script lowers requests, but stale pods
in `Error` state keep their old reservations until explicitly deleted.

**Correct remediation sequence**:
```bash
# 1. Patch CSI driver resource requests
bash scripts/update-csi-resources.sh   # now includes stale-pod deletion + wait

# 2. Verify all ODF pods running (not just Ceph health)
bash scripts/tnf-preflight-validate.sh --odf
# Signal 9 checks mon/osd/mds counts; Signal 10 checks node CPU headroom
```

**Do not proceed to Demo 5 fence validation** if Signal 9 or Signal 10 fail.

See: `docs/hardening/odf-csi-cpu-starvation-v4.21-2026-06-09.md`
See: `docs/adrs/009-odf-tnf-post-install-tuning.md`

---

## Pacemaker / etcd Quick Reference

```bash
SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Full cluster status
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status

# etcd health
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -A5 etcd-clone
ssh -i $SSH_KEY core@192.168.49.21 sudo ss -tlnp | grep 2379

# Fence a node safely
bash scripts/odf-ha-fence-node.sh --target openshift-node2

# Recover etcd after "removed all voters" panic
bash scripts/etcd-pacemaker-recovery.sh \
  --clean-node openshift-node1 --clean-node-ip 192.168.49.21 \
  --corrupt-node openshift-node2 --corrupt-node-ip 192.168.49.22
```

---

## Demo 5 Pre-Validation Checklist

Before running any Demo 5 HA fence validation, the agent must run:

```bash
bash scripts/odf-ha-fence-node.sh --target <node> --skip-preflight  # dry run first
# Then run preflight separately:
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
oc get nodes
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -A5 etcd-clone
for IP in 192.168.49.21 192.168.49.22; do
  ssh -i $SSH_KEY core@$IP sudo ss -tlnp | grep 2379 || echo "$IP: etcd NOT listening"
done
oc get cephcluster -n openshift-storage \
  -o custom-columns="NAME:.metadata.name,HEALTH:.status.ceph.health"
```

If any check fails, **do not proceed** with fence validation. Fix the failing component first.
