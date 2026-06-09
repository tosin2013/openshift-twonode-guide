# 002. Agent-Based Installer (ABI) as Deployment Method

**Status**: Accepted
**Date**: 2026-06-02
**Updated**: 2026-06-03
**Domain**: deployment-automation / installer-strategy

## Context

OpenShift supports multiple installation methods for bare-metal clusters:

| Method | Description | Bare-Metal Suitability | Automation Friendliness |
|---|---|---|---|
| IPI (Installer Provisioned Infrastructure) | Installer manages hardware via Ironic | Good, but requires Metal3/Ironic stack | Complex setup |
| UPI (User Provisioned Infrastructure) | Operator manually provisions nodes | Full control, but all bootstrapping manual | High manual effort |
| ABI (Agent-Based Installer) | Generates a bootable ISO with embedded agent | Purpose-built for disconnected/bare-metal | High — playbook-driven |
| Assisted Installer (SaaS) | Cloud-hosted assisted installation | Requires outbound connectivity | Easy but cloud-dependent |

The project requires a deployment method that:
1. Works on physical bare-metal servers with Redfish BMC.
2. Supports disconnected / air-gap environments (future enhancement).
3. Is automation-friendly and scriptable.
4. Integrates cleanly with the existing `tosin2013/openshift-agent-install` tooling.
5. Handles the specific TNF topology requirements (`featureSet: TechPreviewNoUpgrade`, 2 control-plane nodes, 0 app nodes).

The original Module 3 failure was compounded by the complexity of trying to run the ABI workflow inside nested KubeVirt VMs. The new approach deploys directly to physical nodes (or KVM with sushy-tools), eliminating the nesting.

## Decision

Use the **Agent-Based Installer (ABI)** via the `tosin2013/openshift-agent-install` framework as the sole deployment method.

The `openshift-agent-install` repository provides an Ansible-based automation framework (`create-manifests.yml` playbook) that:
- Accepts a `cluster.yml` and `nodes.yml` as input.
- Generates the `install-config.yaml`, `agent-config.yaml`, and all required manifests.
- Produces a bootable ISO via `openshift-install agent create image`.
- Monitors installation via `openshift-install agent wait-for install-complete`.

This repository will add a `two-node-fencing` example to that framework rather than creating a parallel deployment mechanism.

## Alternatives Considered

### Option A — IPI (Installer Provisioned Infrastructure)
- Installer manages hardware via Metal3/Ironic; well-integrated with OpenShift bare-metal operators
- **Problem:** Requires a full Metal3/Ironic stack as a prerequisite. Complex setup that adds
  dependencies not present in the target edge environment.

### Option B — UPI (User Provisioned Infrastructure)
- Full operator control over all hardware provisioning
- **Problem:** Entirely manual bootstrapping; not automation-friendly. Does not integrate with the
  existing `openshift-agent-install` framework.

### Option C — Assisted Installer (SaaS)
- Cloud-hosted wizard for installation; easiest operator experience
- **Problem:** Requires outbound internet connectivity to the Red Hat Assisted Installer service.
  Incompatible with future air-gap/disconnected requirements.

### Option D — Agent-Based Installer (ABI) (CHOSEN)
- Generates a bootable ISO with embedded agent; no external service dependency
- Purpose-built for bare-metal and disconnected environments
- Integrates with `tosin2013/openshift-agent-install` automation framework

---

## Consequences

**Positive:**
- ABI is specifically designed for bare-metal and disconnected environments.
- Single ISO artifact simplifies deployment logistics — boot the ISO, installation is automated.
- The `openshift-agent-install` framework already handles manifest generation, reducing duplication.
- No dependency on a running OpenShift hub cluster (unlike RHACM-based deployment).
- ISO-based deployment is compatible with both physical Redfish BMC and sushy-tools.
- Naturally supports air-gap via mirror registry (future enhancement).

**Negative:**
- ABI does not support post-installation node additions via the same ISO (day-2 node addition requires a separate process).
- The `openshift-agent-install` framework is community-maintained; upstream changes may require updates to the example templates.
- Installation monitoring (`wait-for install-complete`) must run from a host with network access to the cluster's API VIP — this must be explicitly documented for KVM and bare-metal network topologies.

## Domain Considerations

- The `install-config.yaml` must include `featureSet: TechPreviewNoUpgrade` for TNF. This must be validated in the `cluster.yml` template.
- The `agent-config.yaml` requires static MAC address assignments per node — this is critical for TNF since MAC regeneration was the root cause of Module 3 failures on KubeVirt.
- The `create-manifests.yml` playbook must be run from a bastion host that can reach the cluster network.

## Implementation Plan

1. Fork or reference `tosin2013/openshift-agent-install` in the repository README.
2. Create `examples/two-node-fencing/cluster.yml` with TNF-specific parameters (OCP 4.22, baremetal, OVNKubernetes, 2 control-plane, 0 app nodes, Redfish BMC addresses).
3. Create `examples/two-node-fencing/nodes.yml` with per-node static MAC, IP, and BMC configuration.
4. Document bastion host requirements and network access prerequisites in `docs/deployment-guide.md`.
5. Document the `create-manifests.yml` → ISO generation → `wait-for install-complete` workflow end-to-end.

## ⚠ Known Bootstrap Ordering Constraint (TNF-Specific)

In 2-node TNF, **node1 is both the ABI rendezvous/bootstrap pivot and a real control plane node**. After `bootstrap-complete`, the Cluster Etcd Operator (CEO) must run installer pods on both nodes to write etcd static pod manifests. However, the CEO cannot run the node1 installer pod until the installed kube-apiserver is accessible (post-bootstrap-complete), and the kube-apiserver cannot start until etcd has quorum. Etcd on node2 starts in 2-member "existing" mode, cannot elect a leader without node1, creating a circular deadlock.

**Automated resolution** (Phase 8.5 of `scripts/deploy-tnf-kvm.sh`):
1. Detects the election loop in node2's etcd logs after bootstrap-complete.
2. Injects `--force-new-cluster` into node2's `etcd-pod.yaml` (kubelet restarts etcd as single-member with quorum).
3. Restores the original manifest after etcd is healthy.
4. Waits for the kube-apiserver to restart (up to 5 min crash backoff).
5. The CEO then self-heals: installs node1's etcd manifests and adds node1 as an etcd member.

This is a deterministic failure, not a timing fluke. Without Phase 8.5, every automated deployment will deadlock at this point. The original `example.com` deployment succeeded only because Phase 9 fencing patches were applied manually and changed timing in ways that occasionally allowed the API to come up before the deadlock fully set in.

## Related ADRs

- [001: TNF Topology Selection](001-tnf-topology-selection.md) — defines the TNF topology that
  this installer decision serves
- [003: BMC / Redfish Fencing Strategy](003-bmc-redfish-fencing-strategy.md) — BMC configuration
  that must be reflected in the `nodes.yml` `bmc.address` fields
- [007: KVM + sushy-tools Dev Environment](007-kvm-sushy-tools-dev-environment.md) — the KVM
  environment that ABI deploys into during development

---

## Related PRD Sections

- Section 2.2: The New Approach
- Section 2.3: Source Repositories
- Section 5.1: Phase 1 — Deployment (Configuration Templates)

## References

- [OpenShift Agent-Based Installer Helper — tosin2013/openshift-agent-install](https://github.com/tosin2013/openshift-agent-install)
- [OpenShift 4.22 Agent-Based Installation Documentation](https://docs.openshift.com/container-platform/4.22/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html)
