# Hardening Report: ODF CPU Starvation + Stale Out-of-Service Taints
**Version**: ODF 4.21 / OCP 4.22 TNF  
**Date**: 2026-06-09  
**Severity**: High — blocked Demo 5 HA fence validation; cluster appeared operational but was structurally unsound  
**PMB tags**: `incident`, `hardening`, `v4.21-odf-cpu`

---

## 1. Incident Reference

PMB pin: `INCIDENT SUMMARY v4.21-odf-cpu` — tagged `incident, hardening, v4.21-odf-cpu`  
Related: `docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md` (prior incident, same cluster)

---

## 2. Root Cause Summary

Two compounding failures caused ODF pods (`rook-ceph-mon-a`, `rook-ceph-osd-1`, `rook-ceph-mds-a`) to remain `Pending` indefinitely after ODF deployment on a two-node TNF cluster:

**Primary cause — stale `out-of-service` taints on node2**: The previous day's failed fence attempt (01:48 on 2026-06-09) left `node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule` and `NoExecute` taints on `openshift-node2`. These taints were never removed after the node recovered. As a result, the scheduler could not place any new ODF pods on node2, forcing all scheduling attempts onto node1 exclusively. Node1 reached 98% CPU requests.

**Secondary cause — stale Error-state CSI pods holding CPU reservations**: Even after `scripts/update-csi-resources.sh` was run and the CSI driver CRs were patched to lower CPU requests, the existing CSI controller pods that were in `Error` / `CrashLoopBackOff` state retained their pre-patch CPU reservations. New replacement pods could not schedule because the old pods had not released their allocations.

**Detection gap**: `CephCluster` reported `HEALTH_OK` throughout the incident, providing false confidence that ODF was healthy. The real signal — that `rook-ceph-osd-1` was `Pending` and only one OSD was running — was not visible from the health string alone.

**Fix**: Remove the two stale taints from node2 (10-second operation). ODF pods immediately scheduled on node2, node1 CPU dropped from 98% to normal, and all 7 core ODF pods reached `Running` within 2 minutes. No node resize was required.

---

## 3. Timeline

| Time | Event |
|------|-------|
| 2026-06-08 01:48 | Pacemaker attempted to fence node1 — attempt **failed** |
| 2026-06-08 01:48 | `out-of-service` taints applied to node2 as part of previous Demo 5 attempt — **never removed** |
| 2026-06-09 09:00 | Cluster inspected: node1 at 98% CPU, 6 ODF pods Pending |
| 2026-06-09 09:06 | `CephCluster` reported `HEALTH_OK` — false confidence |
| 2026-06-09 09:16 | Root cause identified: stale `out-of-service:NoSchedule + NoExecute` on node2 |
| 2026-06-09 09:18 | Taints removed: `oc adm taint node openshift-node2 out-of-service:NoSchedule- out-of-service:NoExecute-` |
| 2026-06-09 09:18 | Stale Error pods deleted; Pacemaker cleanup run |
| 2026-06-09 09:20 | All 7 ODF core pods Running; `HEALTH_OK`; Pacemaker clean; no Failed Resource Actions |

---

## 4. ADRs Updated

### ADR-009: ODF TNF Post-Install Tuning
**File**: `docs/adrs/009-odf-tnf-post-install-tuning.md`

**Before**: Implementation Plan showed `bash scripts/update-csi-resources.sh` with a one-line verification. No mention of stale pods or pod count verification.

**After**: Added `⚠ Incident-Driven Constraint (2026-06-09)` section documenting:
- Stale Error-state CSI pods retain pre-patch CPU reservations
- `HEALTH_OK` does not confirm all ODF pods are scheduled
- Implementation Plan now includes: patch → delete stale pods → wait → verify pod count → confirm health

---

## 5. Script Patches

### `scripts/update-csi-resources.sh`
**Change type**: Guard clauses + stale pod cleanup + wait loop + exit codes

| Addition | Rationale |
|---|---|
| Guard clause: check `KUBECONFIG` and namespace exist before patching | Silent failure if ODF not deployed |
| Guard clause: verify both CSI driver CRs exist | Patch fails silently if CRs missing |
| After patching: delete all `Error`/`CrashLoop` CSI pods | Stale pods hold pre-patch CPU allocations; replacements cannot schedule without this |
| Wait loop (300s timeout): poll until all CSI pods Running | Script previously returned before replacement pods were up |
| Final verification: print pod count and Ceph health | Confirms success, not just "patch applied" |
| Exit codes: 0=success, 1=preflight fail, 2=timeout | Enables scripted use in CI/automation |

### `scripts/tnf-preflight-validate.sh`
**Change type**: Two new signals added to `--odf` flag

| Signal | Check | Failure Condition |
|---|---|---|
| **Signal 9: ODF core pod count** | `oc get pods -n openshift-storage \| grep rook-ceph-mon/osd/mds \| grep Running \| wc -l` | FAIL if <2 mons Running; FAIL if <2 OSDs Running; WARN if 0 MDS Running |
| **Signal 10: Node CPU headroom** | Parse `oc describe node` Allocated resources % | FAIL if ≥90%; WARN if ≥75% |

Signal 5 (stale out-of-service taints) was already present and would have caught this incident if run. The new lesson: **run `tnf-preflight-validate.sh --odf` before any ODF operation**, not just before fencing.

---

## 6. CLAUDE.md Addition

Added to **Known Failure Patterns — v4.21** section:

```
### [WARNING] ODF CSI resource starvation → ODF pods stuck Pending after deployment

Symptom pattern: rook-ceph-mon-a, rook-ceph-osd-1, rook-ceph-mds-a stuck Pending.
StorageCluster phase Error. CephCluster may still report HEALTH_OK. Node1 ≥90% CPU.

Always verify after update-csi-resources.sh:
1. Delete stale Error/CrashLoop CSI pods
2. Run preflight --odf: bash scripts/tnf-preflight-validate.sh --odf

Root cause: stale out-of-service taints on node2 (from failed fence) forced all ODF
pods onto node1; stale Error pods held pre-patch CPU allocations.

See: docs/hardening/odf-csi-cpu-starvation-v4.21-2026-06-09.md
```

---

## 7. Validation Gaps and New Checks

| Gap | Signal | Command | Expected | Failure |
|-----|--------|---------|----------|---------|
| HEALTH_OK masks Pending pods | Signal 9: ODF pod count | `oc get pods -n openshift-storage \| grep rook-ceph-osd.*Running \| wc -l` | ≥2 | <2 OSDs Running |
| Node CPU starvation not detected | Signal 10: CPU headroom | Parse `oc describe node` Allocated cpu % | <75% | ≥90% = FAIL, ≥75% = WARN |
| Stale taints not checked before ODF ops | Signal 5 (existing) | `oc get node -o jsonpath='{.spec.taints}'` | No out-of-service taints | Any out-of-service taint = FAIL |

**Location**: All three signals now present in `scripts/tnf-preflight-validate.sh --odf`.

**New procedural rule**: Run `bash scripts/tnf-preflight-validate.sh --odf` at the start of every session involving ODF, not only before fencing.

---

## 8. Verification

Confirmed after applying all fixes (2026-06-09 13:20):

```
ODF pod summary:    41 Running, 11 Completed, 1 Pending (noobaa — unrelated, not needed for demos)
mon-a:              Running ✅
mon-b:              Running ✅
mon-c (floating):   Running ✅
osd-0:              Running ✅
osd-1:              Running ✅
mds-a:              Running ✅
mds-b:              Running ✅
CephCluster health: HEALTH_OK ✅
Pacemaker:          Both nodes Online, etcd-clone Started on both, no Failed Resource Actions ✅
node2 taints:       CLEAN (empty) ✅
```

**The original failure (ODF pods Pending due to CPU starvation) cannot be reproduced** after removing the stale taints. Signal 5 and Signal 10 in `tnf-preflight-validate.sh --odf` would detect both the taint and the CPU starvation conditions before they compound into an incident.

---

## 9. Pre-Conditions for Demo 5 Fence Validation

The cluster is now in the required state to attempt Demo 5 HA fence validation:

- [x] Both nodes Ready, Online in Pacemaker
- [x] etcd: 2 members, both Started
- [x] Pacemaker: no Failed Resource Actions
- [x] STONITH: `openshift-node1_redfish` and `openshift-node2_redfish` Started
- [x] CephCluster: HEALTH_OK
- [x] 2 OSDs Running (full replica protection)
- [x] 3 monitors Running
- [x] No stale out-of-service taints

Next step: `bash scripts/tnf-preflight-validate.sh --odf` → if all pass → `bash scripts/odf-ha-fence-node.sh`
