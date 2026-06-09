# Changelog

All notable changes to this guide are documented here. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

---

## [Unreleased]

### Added

- **Demo 6: VM Live Migration** — new demo showing zero-downtime VM migration between nodes using ODF CephFS (`ReadWriteMany`) storage. Covers `virtctl migrate` (manual) and `oc adm drain` (maintenance-driven) triggers, heartbeat continuity validation, and KVM-specific tuning for migration bandwidth. Clearly scoped as experimental on 2-node TNF; documents Red Hat's 3-worker-node recommendation and why this topology is still functional.

---

## [0.2.0] — 2026-06-09

### Added

- **Demo 2: Database HA** — end-to-end validated. PostgreSQL `StatefulSet` with a local PV survives both planned (`oc drain`) and unplanned (`fence_redfish`) node failure. Pod reschedules to the surviving node with persistent data intact.
- **Demo 3: OpenShift Virtualization** — end-to-end validated. KubeVirt VM (`legacy-inventory`, `RunStrategy: Always`) restarts on surviving node after fence. Key findings: `evictionStrategy` must be `None` for local-RWO VMs; `virt-api` webhook pods on the dead node must be force-deleted to restore webhook function.
- **Demo 4: Edge AI Inference** — end-to-end validated. YOLOv8-compatible inference service deployed with `initContainer` dependency installation pattern, survives node fence cycle. Confirmed CPU-based inference on OpenShift with `restricted:latest` PodSecurity.
- **Demo 5: DRBD Edge Storage** — ODF 4.21 + DRBD deployment procedure documented and tested. Floating Ceph monitor (`mon-c`) pattern established. HA fence validation pending (blocked on live cluster with Pacemaker STONITH).
- **ADR-008 through ADR-011** — four new ODF-specific ADRs covering: pool replica strategy (`reconcileStrategy: ignore`), post-install resource tuning, `mon-c` image version consistency, and Demo 5 safe fencing procedure.
- **ADR reorganization** — all 11 ADRs standardized with `Alternatives Considered`, `Related ADRs`, `Domain`, and `Updated` fields. Unified ADR index at `docs/adrs/README.md`.
- **scripts/odf-ha-fence-node.sh** — safe ODF fencing script enforcing STONITH-before-taints order (ADR-011).
- **scripts/etcd-pacemaker-recovery.sh** — automated etcd recovery via `crm_attribute force_new_cluster` and `pcs resource cleanup`.
- **scripts/tnf-preflight-validate.sh** — 7-signal cluster health check (quorum, etcd, API, operators, STONITH, ODF) to run before any disruptive operation.
- **scripts/update-csi-resources.sh** — caps ODF CSI driver CPU/memory to prevent resource starvation on KVM.
- **scripts/mon-deployment.sh** — deploys the floating Ceph monitor from the externalized template at `examples/two-node-drbd/mon-template.yaml`.
- **examples/two-node-drbd/** — full set of ODF+DRBD manifests: `storagecluster-drbd.yaml`, `ceph-pools-size2.yaml`, `local-storage-storageclass.yaml`, `osd-pvs.yaml`, `mon-template.yaml`.
- **docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md** — incident report for the 2026-06-08 etcd panic; covers root cause, timeline, and 8-item prevention checklist.
- **docs/troubleshooting.md §8** — new ODF + Demo 5 section covering: `panic: removed all voters`, MDS scheduling failures, OSD crash loop after fence, OCS operator pool size reversion, and `mon-c` version skew.
- **CLAUDE.md** — AI agent guidance file with key project lessons, ADR references, and safe fencing rules.
- **RELEASE-PLAN.md** — v0.2.0 release plan with 14 tasks, schedule, and definition of done.
- **TODO.md** — rewritten from auto-generated 60-task list to an accurate 9-task open/done summary.

### Fixed

- Demo 1 pre-flight check: replaced ad-hoc `oc get nodes` / `pcs status` block with `scripts/tnf-preflight-validate.sh` call. Provides a single pass/fail signal before any disruptive operation.
- Demo 5 fence validation section: replaced in-line partial health check with `scripts/tnf-preflight-validate.sh`.
- ADR numbering collision: `ADR-004-odf-tnf-demo5-fencing-procedure.md` conflicted with `004-etcd-outside-cluster.md`. Renamed to `011-odf-tnf-demo5-fencing-procedure.md`. All cross-references updated.
- ADR naming inconsistency: ODF ADRs used `ADR-00N-` prefix while architecture ADRs used `00N-`. Dropped the `ADR-` prefix from all four ODF ADRs.
- `mon-template.yaml` and `mon.yaml` at repository root: `mon-template.yaml` moved to `examples/two-node-drbd/`; stale `mon.yaml` deleted; `mon-deployment.sh` updated to read from the new location.

### Changed

- `docs/troubleshooting.md`: expanded from 443 to 719 lines; added section 8 (ODF + Demo 5) with five sub-sections covering known failure modes.
- All ADRs: added `Alternatives Considered`, `Related ADRs`, `Updated` date, and consistent `Status:` header format.

---

## [0.1.0] — 2026-06-03

### Added

- **Automated etcd quorum recovery (Phase 8.5)** — `scripts/deploy-tnf-kvm.sh` now detects the deterministic TNF bootstrap deadlock (both nodes stall waiting for etcd quorum at `~35%`) and automatically recovers by force-promoting a single-member etcd cluster on node1, then re-adding node2 after stabilization. No manual intervention required.
- **Demo 1: Fencing Validation** — end-to-end validated against OCP 4.22.0-rc.5 TNF cluster on KVM/IBM Cloud. Includes hard node failure, Pacemaker STONITH trigger, etcd failover, and full cluster self-heal. Observed ~26s application downtime during hard failure.
- **IBM Cloud KVM deployment record** — `docs/deployments/tnf-kvm-ibmcloud-2026-06-03.md` documents the full deployment with prerequisites, ordered steps, known issues, and validation output.
- **Architecture Mermaid diagrams** — replaced ASCII art in `docs/architecture.md` and `docs/kvm-developer-guide.md` with Mermaid flowcharts and sequence diagrams.
- **KVM Developer Guide Quick Start** — added TL;DR section to `docs/kvm-developer-guide.md` for experienced operators who want a fast path.
- **GitHub Pages site** — MkDocs + Material theme, deployed via GitHub Actions on push to `main`.
- **CONTRIBUTING.md** — guide for adding new demos, ADRs, and deployment records.

### Fixed

- `fence_redfish` command in Demo 1: replaced unsupported `-b` flag with `--systems-uri` and added `--ipport 8000`. This was identified during the first live demo run.
- `etcdctl` access in Demo 1: updated all commands to use `oc exec -n openshift-etcd ... -c etcdctl` to match the stacked etcd static pod topology.
- Node IPs in Demo 1 updated from generic `192.168.150.x` to the actual `192.168.49.x` range used in the KVM environment.

### Changed

- Sensitive lab information masked across all documentation: public IP replaced with `<YOUR-PUBLIC-IP>`, private IP with `<HOST-PRIVATE-IP>`, base domain with `<YOUR-BASE-DOMAIN>`.
- `demos/` directory moved to `docs/demos/` so all documentation is co-located under `docs/`.
- `scripts/bootstrap.sh`: replaced hardcoded IBM Cloud DNS servers with public resolvers (`8.8.8.8`, `1.1.1.1`); `HOST_PRIVATE_IP` is now a required environment variable.

---

[Unreleased]: https://github.com/tosin2013/openshift-twonode-guide/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tosin2013/openshift-twonode-guide/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tosin2013/openshift-twonode-guide/releases/tag/v0.1.0
