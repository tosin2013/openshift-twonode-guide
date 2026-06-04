# Changelog

All notable changes to this guide are documented here. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

---

## [Unreleased]

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

[Unreleased]: https://github.com/tosin2013/openshift-twonode-guide/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tosin2013/openshift-twonode-guide/releases/tag/v0.1.0
