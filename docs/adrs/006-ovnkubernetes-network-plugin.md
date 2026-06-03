# 006. OVNKubernetes as the Required Network Plugin

**Status**: Accepted
**Date**: 2026-06-02
**Domain**: network-architecture / cni-plugin

## Context

OpenShift supports two CNI network plugins:

| Plugin | Status in OCP 4.22 | TNF Compatibility |
|---|---|---|
| OpenShiftSDN | Deprecated (removed in future versions) | Not supported for TNF |
| OVNKubernetes | Default, actively developed | **Required for TNF** |

The TNF topology has an explicit dependency on OVNKubernetes. The OpenShift documentation for Two-Node with Fencing specifies OVNKubernetes as a required parameter in the install configuration. OpenShiftSDN does not support the network features required by the TNF topology (specifically, the node network topology awareness and the OVN-based logical network management that TNF relies on).

Additionally, OVNKubernetes is the strategic direction for OpenShift networking, with OpenShiftSDN deprecated as of OCP 4.14. Any new deployment should use OVNKubernetes regardless of topology.

## Decision

Use **OVNKubernetes** as the network plugin. This is a hard requirement for TNF and aligns with OpenShift's strategic networking direction.

In the configuration templates (`examples/two-node-fencing/cluster.yml`), this is expressed as:

```yaml
network_type: OVNKubernetes
```

No alternative network plugin will be documented or supported for this repository.

## Consequences

**Positive:**
- Required for TNF topology — this is the only compliant choice.
- OVNKubernetes is the active, feature-rich CNI plugin for OpenShift; all future features will be OVNKubernetes-only.
- OVNKubernetes provides superior network policy implementation compared to OpenShiftSDN.
- Aligns with Red Hat's deprecation of OpenShiftSDN, ensuring this guide remains current.

**Negative:**
- OVNKubernetes can have higher memory and CPU overhead on small nodes compared to OpenShiftSDN — relevant for resource-constrained edge hardware. The deployment guide should include minimum resource recommendations.
- Troubleshooting OVNKubernetes networking issues requires familiarity with OVN concepts (logical switches, logical routers, flow tables) rather than simpler OpenFlow debugging from SDN.
- On KVM development environments, OVNKubernetes performance tuning may be needed if the host has limited resources.

## Domain Considerations

- **Resource requirements**: Document minimum node resource requirements (CPU/RAM) accounting for OVNKubernetes control-plane overhead in `docs/architecture.md`.
- **Network diagnostics**: The troubleshooting guide should include OVNKubernetes-specific diagnostic commands (`ovn-nbctl`, `ovn-sbctl`, `ovs-vsctl`) for network connectivity issues.
- **MTU configuration**: On KVM environments, MTU settings for the cluster network may need adjustment depending on the host bridge configuration. Document this in the KVM deployment section.

## Implementation Plan

1. Set `network_type: OVNKubernetes` in `examples/two-node-fencing/cluster.yml`.
2. Document the OVNKubernetes requirement and rationale in `docs/architecture.md`.
3. Include OVNKubernetes-specific network validation steps in `docs/deployment-guide.md` (post-install validation).
4. Add OVNKubernetes MTU troubleshooting notes in `docs/troubleshooting.md` for KVM environments.

## Related PRD Sections

- Section 5.1: Phase 1 — Deployment (Configuration Templates, `network_type: OVNKubernetes`)

## References

- [OpenShift 4.22 Networking — About the OVN-Kubernetes network plugin](https://docs.openshift.com/container-platform/4.22/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)
- [OpenShift SDN deprecation notice — OCP 4.14 release notes](https://docs.openshift.com/container-platform/4.14/release_notes/ocp-4-14-release-notes.html)
