# Release Plan — openshift-twonode-guide v1.0.0

**Version**: v1.0.0  
**Goal**: Ship a complete, production-quality two-node OpenShift guide with all five demos validated, full documentation, and a hardened Demo 5 HA validation procedure.  
**Target date**: 2026-06-27  
**Planned by**: Agent session 2026-06-09  

---

## Release Goal

Deliver the first fully-validated `openshift-twonode-guide` release: Demos 1–5 all executable end-to-end, deployment and troubleshooting guides complete, ADRs cross-referenced and up to date, and the etcd-panic failure class structurally prevented.

---

## Scope — Work Items (Priority Order)

### INFRA
| # | Task | Priority | Notes |
|---|------|----------|-------|
| I-1 | Commit all uncommitted changes from 2026-06-09 session | Critical | ADR reorganization (ADR-008–011), CLAUDE.md, hardening scripts, mon-template.yaml move, docs/hardening/ |
| I-2 | Create `CHANGELOG.md` with history since initial commit | High | Covers Demo 1–5 work, etcd incident, ADR reorganization |
| I-3 | Add GitHub Actions CI for YAML lint on `examples/` templates | Medium | Prevent regressions on `cluster.yml`, `nodes.yml`, ODF manifests |

### FIX
| # | Task | Priority | Notes |
|---|------|----------|-------|
| F-1 | Complete Demo 5 HA fence validation (pcs node fence path) | Critical | Run `scripts/odf-ha-fence-node.sh`, confirm RWO workload failovers to surviving node, verify data integrity |
| F-2 | Update `TODO.md` to reflect actual completion state | High | Auto-generated 2026-06-02; majority of architecture-wide tasks are already done |

### HARDENING
| # | Task | Priority | Notes |
|---|------|----------|-------|
| H-1 | Wire `tnf-preflight-validate.sh` into Demo 1 and Demo 5 pre-flight steps | High | 7-signal health check must run before any disruptive operation |
| H-2 | Add `pcs resource restart etcd-clone` to Demo 1 post-fence recovery steps | High | PMB lesson: Pacemaker shows etcd-clone Stopped after fence; must restart manually |
| H-3 | Verify `scripts/etcd-pacemaker-recovery.sh` is executable and tested on live cluster | Medium | Created during hardening; not yet validated against a real recovery scenario |

### DOCS
| # | Task | Priority | Notes |
|---|------|----------|-------|
| D-1 | Write comprehensive `docs/architecture.md` | High | TNF vs TNA table, Pacemaker/STONITH/etcd model, DRBD architecture, network (OVNKubernetes), storage tiers |
| D-2 | Fill `docs/deployment-guide.md` gaps: KVM section, sushy-tools setup, static MAC procedure, BMC address mapping | High | Core of the guide; ADR-002, ADR-003, ADR-007 all reference this file |
| D-3 | Write `docs/troubleshooting.md` | High | Must cover: etcd `panic: removed all voters`, slow disk latency warnings, OVNKubernetes MTU, fencing timeout, MDS scheduling |
| D-4 | Create IBM Cloud hardware specification (`docs/hardware-spec-ibm-cloud.md`) | High | User requested: recommend bare-metal profile so all 5 demos can run; include vCPU, RAM, disk, network requirements |
| D-5 | Add `examples/two-node-arbiter/` stub and TNA reference in README | Low | Pointer for users who want GA-supported topology; no full implementation required |

---

## ADR Constraints Applying to This Release

| ADR | Constraint |
|-----|-----------|
| [011: Demo 5 Fencing Procedure](docs/adrs/011-odf-tnf-demo5-fencing-procedure.md) | `pcs node fence` MUST precede `out-of-service` taints; taints-first causes CEO etcd-member-removal → API outage |
| [004: etcd Outside Cluster](docs/adrs/004-etcd-outside-cluster.md) | Use `pcs status` (not `oc`) for etcd health; CEO is a second actor that removes members independently of Pacemaker |
| [008: Pool Replica Strategy](docs/adrs/008-odf-tnf-pool-replica-strategy.md) | `reconcileStrategy: ignore` must be verified post-ODF-upgrade; OCS may re-enable manage |
| [009: Post-Install Tuning](docs/adrs/009-odf-tnf-post-install-tuning.md) | `update-csi-resources.sh` must be re-run after any ODF upgrade |
| [002: ABI Installer](docs/adrs/002-agent-based-installer.md) | Bootstrap ordering deadlock (Phase 8.5) is deterministic; `deploy-tnf-kvm.sh` automation required |

---

## Known Risks

1. **Demo 5 fence path untested end-to-end** — the `odf-ha-fence-node.sh` script was written but never run successfully against a healthy `HEALTH_OK` cluster with Pacemaker STONITH working.
2. **sushy-tools STONITH timeout** — if `pcs node fence` times out in the KVM environment, Demo 5 cannot complete; must validate sushy-tools responds within Pacemaker's default timeout.
3. **ODF version skew on re-deployment** — `CEPH_IMAGE` SHA in `mon-deployment.sh` is pinned to 20.1.0-185; upgrading ODF could change this.
4. **Hardware spec accuracy** — IBM Cloud bare-metal profiles change; the spec doc must be validated against current IBM Cloud catalog.
5. **TODO.md staleness** — 60 auto-generated tasks from 2026-06-02 are mostly stale; leaving them creates false impression of incomplete work.

---

## Definition of Done

- [ ] All INFRA items committed and CI passing
- [ ] F-1: Demo 5 HA fence validation runs end-to-end successfully with `scripts/odf-ha-fence-node.sh`
- [ ] F-2: `TODO.md` updated to reflect actual state
- [ ] All HARDENING items applied and smoke-tested
- [ ] D-1 through D-4 written, reviewed, and committed
- [ ] `CHANGELOG.md` created and covers all work from initial commit to v1.0.0
- [ ] All 11 ADRs committed and consistent with implementation
- [ ] GitHub Pages site builds without errors (`mkdocs build`)
- [ ] `git tag v1.0.0` created and pushed

---

## Task Schedule

| Task | Owner | Due | Effort |
|------|-------|-----|--------|
| I-1 — Commit session changes | Agent | 2026-06-09 | 30 min |
| F-2 — Update TODO.md | Agent | 2026-06-10 | 1 hr |
| H-1 — Wire preflight to demos | Agent | 2026-06-10 | 1 hr |
| H-2 — Demo 1 post-fence cleanup | Agent | 2026-06-10 | 30 min |
| D-4 — IBM Cloud hardware spec | Agent | 2026-06-11 | 2 hr |
| D-1 — architecture.md | Agent | 2026-06-13 | 3 hr |
| D-2 — deployment-guide.md gaps | Agent | 2026-06-16 | 4 hr |
| D-3 — troubleshooting.md | Agent | 2026-06-18 | 3 hr |
| F-1 — Demo 5 fence validation | User + Agent | 2026-06-20 | 2 hr (live cluster required) |
| H-3 — Validate etcd recovery script | User + Agent | 2026-06-20 | 1 hr (live cluster required) |
| I-2 — CHANGELOG.md | Agent | 2026-06-23 | 2 hr |
| I-3 — GitHub Actions CI | Agent | 2026-06-25 | 1 hr |
| D-5 — TNA stub | Agent | 2026-06-25 | 30 min |
| Final review + git tag v1.0.0 | Agent | 2026-06-27 | 1 hr |

---

## Progress Tracking

Update this file as items complete. Change `[ ]` to `[x]` in Definition of Done.

To check status in any session: `pmb recall "release plan v1.0.0"`.

_This plan was created 2026-06-09 by the Cursor agent. Pinned in PMB under tags: release, plan, v1.0.0_
