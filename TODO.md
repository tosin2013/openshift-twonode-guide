# TODO — openshift-twonode-guide

_Last reviewed: 2026-06-09. The 60 ADR-generated tasks from the 2026-06-02
auto-generation are now collapsed here; the vast majority were completed
during the initial v0.1.0 development sprint. Only genuine open work
remains below._

---

## Summary

| Category | Open | Done |
|----------|------|------|
| HARDENING | 3 | 5 |
| FIX | 1 | 1 |
| DOCS | 3 | 6 |
| INFRA | 2 | 1 |
| **Total** | **9** | **13** |

Release plan: [RELEASE-PLAN.md](RELEASE-PLAN.md) | Version target: v0.2.0 | Due: 2026-06-27

---

## Open — Must Do Before v0.2.0

### HARDENING

- [ ] **H-1** Wire `scripts/tnf-preflight-validate.sh` into Demo 1 and Demo 5
  pre-flight steps (add a "Run pre-flight check" step at the top of each
  demo README before any destructive operation).
  _File: `docs/demos/01-fencing-validation/README.md`,
  `docs/demos/05-drbd-edge-storage/README.md`_

- [ ] **H-2** Add `pcs resource restart etcd-clone` to Demo 1 **Step 7**
  (post-fence recovery). Pacemaker shows `etcd-clone: Stopped` after
  fence even when the etcd container is running; the restart clears the
  stale resource state.
  _File: `docs/demos/01-fencing-validation/README.md`_

- [ ] **H-3** Run `scripts/etcd-pacemaker-recovery.sh` against a live
  recovery scenario to validate it works end-to-end. Script was created
  during the 2026-06-08 hardening session but has not been exercised on
  a real cluster since writing.
  _Requires: live TNF cluster, intentionally triggered etcd panic_

### FIX

- [ ] **F-1** Complete Demo 5 HA fence validation using
  `scripts/odf-ha-fence-node.sh`. The script must run against a healthy
  `HEALTH_OK` ODF cluster with Pacemaker STONITH active. Confirm
  the RWO workload pod reschedules to the surviving node and that
  data integrity is maintained.
  _Requires: live TNF + ODF cluster with fence_redfish working_
  **⚠ BLOCKER: Demo 5 is not fully validated until this passes.**

### DOCS

- [ ] **D-3** Add ODF/etcd panic section to `docs/troubleshooting.md`.
  The 2026-06-08 incident ("panic: removed all voters") is documented in
  the hardening report but NOT in the troubleshooting guide. Add a new
  section **8. ODF + Demo 5 Specific Issues** covering:
  - "panic: removed all voters" — cause (CEO removes member when
    `out-of-service` taint applied before STONITH), correct safe
    sequence, and recovery procedure (link to
    `docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md`)
  - MDS pod scheduling failure (insufficient CPU on small KVM host)
  - OSD crash loop after forced fence (clear PG inconsistency)
  _File: `docs/troubleshooting.md`_

- [ ] **D-4** Create `docs/hardware-spec-ibm-cloud.md`. Recommend a
  specific IBM Cloud bare-metal server profile that can run all 5 demos.
  Include: recommended profile SKU, vCPU count, RAM, disk layout (boot,
  etcd NVMe, OSD disks), network, and estimated hourly cost.
  _Section 7 of `docs/architecture.md` has generic minimums; this doc
  gives an actionable IBM Cloud-specific recommendation._

- [ ] **D-5** Add `examples/two-node-arbiter/` stub. A minimal
  `README.md` explaining TNA topology, when to choose it over TNF, and
  a pointer to the OCP docs. No full implementation required.
  Also update `docs/architecture.md` section 1 to link to this stub.

### INFRA

- [ ] **I-2** Update `docs/changelog.md` with v0.2.0 entry covering:
  Demos 2–5 validation, Demo 5 etcd panic incident + hardening,
  ADR reorganisation (ADR-008–011), new scripts (5), CLAUDE.md.
  _File: `docs/changelog.md`_

- [ ] **I-3** Add GitHub Actions CI workflow for YAML lint on
  `examples/` templates. Lint `cluster.yml`, `nodes.yml`, and all
  `*.yaml` files in `examples/two-node-drbd/` on every PR to `main`.
  _File: `.github/workflows/yaml-lint.yml`_

---

## Open — Future (Non-Blocking for v0.2.0)

- [ ] **INFRA** Disconnected / Air-Gap Support — templates and docs for
  TNF deployment without internet access using a local mirror registry.

- [ ] **INFRA** RHACM Integration — `rhacm/` directory with
  `ClusterDeployment` and `AgentClusterInstall` manifests when TNF
  via RHACM is stable.

- [ ] **INFRA** AAP Workflow — convert demo scripts to Ansible playbooks
  runnable from Ansible Automation Platform.

---

## Completed ✓

### ADR Implementation (v0.1.0 — all done)

All 60 ADR-generated tasks from the 2026-06-02 auto-generation are
complete. Key evidence:

| Deliverable | Location | ADR |
|-------------|----------|-----|
| `featureSet: TechPreviewNoUpgrade` | `examples/two-node-fencing/cluster.yml` | 001 |
| `platform_type: baremetal`, `control_plane_replicas: 2` | `examples/two-node-fencing/cluster.yml` | 001 |
| TNF vs TNA comparison table + Mermaid diagrams | `docs/architecture.md §1–2` | 001 |
| `examples/two-node-fencing/cluster.yml` + `nodes.yml` | `examples/two-node-fencing/` | 002 |
| ABI workflow (`create-manifests.yml` → ISO → boot → wait) | `docs/deployment-guide.md §5–7` | 002 |
| sushy-tools install, config, systemd service | `docs/deployment-guide.md §2.3` | 003, 007 |
| `fence_redfish` STONITH setup + verification | `docs/deployment-guide.md §2.5–2.6` | 003 |
| Pacemaker STONITH post-install validation | `docs/deployment-guide.md §8.2` | 003 |
| etcd outside-cluster documentation | `docs/architecture.md §4` | 004 |
| etcd recovery scripts | `scripts/etcd-pacemaker-recovery.sh` | 004 |
| etcd preflight validation | `scripts/tnf-preflight-validate.sh` | 004 |
| LVM Operator local storage docs | `docs/deployment-guide.md §8.4` | 005 |
| OVNKubernetes troubleshooting | `docs/troubleshooting.md §6` | 006 |
| Static MAC libvirt VM creation | `docs/deployment-guide.md §2.5` | 007 |
| VM UUID → Redfish URL mapping | `docs/deployment-guide.md §2.6` | 007 |
| KVM vs Bare Metal comparison table | `docs/deployment-guide.md §9` | 007 |
| `docs/architecture.md` KVM hardware requirements | `docs/architecture.md §7` | 007 |

### Demos (v0.1.0 / validated 2026-06-03 to 2026-06-08)

| Demo | Status |
|------|--------|
| Demo 1: Fencing Validation | ✅ Validated (OCP 4.22 KVM, ~26s downtime observed) |
| Demo 2: Database HA (PostgreSQL StatefulSet) | ✅ Validated |
| Demo 3: OpenShift Virtualization (KubeVirt VM HA) | ✅ Validated |
| Demo 4: Edge AI Inference (YOLOv8) | ✅ Validated |
| Demo 5: DRBD Edge Storage (ODF + DRBD) | 🔶 Deployed + hardened; HA fence validation pending |

### Hardening (v0.2.0 sprint — done)

| Deliverable | Status |
|-------------|--------|
| `scripts/odf-ha-fence-node.sh` — safe ODF fencing script | ✅ Created |
| `scripts/etcd-pacemaker-recovery.sh` — automated etcd recovery | ✅ Created |
| `scripts/tnf-preflight-validate.sh` — 7-signal health check | ✅ Created |
| `scripts/update-csi-resources.sh` — ODF CSI resource cap | ✅ Created |
| `docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md` — incident report | ✅ Created |
| ADR-011: safe fencing procedure with STONITH-before-taints constraint | ✅ Created |
| ADR-008–010: ODF pool strategy, tuning, mon-c image consistency | ✅ Created |
| CLAUDE.md: agent guidance with key lessons and ADR references | ✅ Created |

---

_This file is maintained by hand. Do not auto-regenerate — the original
ADR-task generator ran on 2026-06-02 before most implementation was done._
