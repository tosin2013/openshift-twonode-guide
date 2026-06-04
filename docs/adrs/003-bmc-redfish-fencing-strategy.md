# 003. BMC / Redfish Fencing Strategy

**Status**: Accepted
**Date**: 2026-06-02
**Domain**: high-availability / fencing / hardware-management

## Context

TNF topology requires each node to have a BMC (Baseboard Management Controller) accessible via Redfish or IPMI so that Pacemaker can perform STONITH (Shoot The Other Node In The Head) operations. This is a hard architectural requirement — TNF cannot function without remote power control.

Two environments must be supported:

1. **Production / Bare Metal**: Physical servers with real Redfish-capable BMCs (Dell iDRAC, HP iLO, Lenovo XCC, Supermicro BMC, etc.)
2. **Development / KVM**: KVM virtual machines managed by libvirt on a local host — no physical BMC present.

The original Module 3 failure was caused by using `fakefish-kubevirt` as a Redfish emulator inside nested KubeVirt VMs. This approach was fragile because:
- fakefish-kubevirt is not a true Redfish implementation; it maps Redfish power calls to Kubernetes VM lifecycle operations.
- The UDN network used for the two-node cluster was unreachable from outside, breaking fencing agent connectivity.
- MAC address regeneration on KubeVirt VM restart broke static network configuration.

A replacement emulator that provides genuine Redfish semantics without nested virtualization is required for the development path.

## Decision

**For production bare metal**: Use `fence_redfish` as the Pacemaker STONITH agent, configured with each node's BMC IP, Redfish credentials, and system ID. This is the canonical fencing mechanism for TNF.

**For development on KVM**: Use `sushy-tools` (`sushy-emulator`) as the Redfish emulator. sushy-tools presents a standard Redfish API on top of libvirt, allowing `fence_redfish` to issue power-off/power-on commands against KVM VMs using the same Redfish protocol as production BMCs.

This unified approach means:
- The same Pacemaker resource configuration (using `fence_redfish`) works in both environments.
- Only the BMC address and credentials differ between bare-metal and KVM deployments.
- Development testing of fencing behavior is a faithful simulation of production behavior.

## Consequences

**Positive:**
- sushy-tools is a Red Hat-maintained, production-quality Redfish emulator — not a hack.
- Single fencing agent (`fence_redfish`) used in both environments reduces configuration drift.
- Eliminates all fragility from the original nested KubeVirt + fakefish-kubevirt approach.
- sushy-tools exposes the KVM VMs on the development host as Redfish Systems, allowing genuine power-state control.
- Fencing validation (Demo 1) can be executed on KVM with identical scripts used on bare metal.

**Negative:**
- sushy-tools must be installed and configured on the KVM host before cluster deployment — adds a pre-requisite setup step.
- sushy-tools requires libvirt access on the host; the bastion and the KVM host may be the same machine (document this clearly).
- Physical BMC access requires firewall rules permitting the cluster nodes to reach each other's BMC network — must be documented.
- Fencing timeout tuning may differ between sushy-tools (fast libvirt power-off) and real BMC (variable response times).

## Domain Considerations

- **Pacemaker resource configuration**: The `stonith:fence_redfish` resource must be created with correct `pcmk_host_map` entries and `power_timeout` / `login_timeout` values that account for real BMC latency.
- **Fencing validation**: The `docs/demos/01-fencing-validation/` scenario uses `fence_redfish` directly (as a manual test) before validating that Pacemaker triggers it automatically. This two-step validation is critical.
- **Network segmentation**: In production, the BMC network (IPMI/Redfish) is typically isolated from the cluster network. The deployment guide must document that Pacemaker needs routed access to the BMC network from within the node OS.

## Implementation Plan

1. Document sushy-tools installation and configuration in `docs/deployment-guide.md` (KVM section).
2. Provide sushy-tools systemd service configuration or container run command.
3. Document `fence_redfish` STONITH resource creation commands for both bare-metal and KVM environments.
4. Include BMC connectivity validation steps in the pre-deployment checklist.
5. In `docs/demos/01-fencing-validation/`, include a manual `fence_redfish` test before the automated Pacemaker test.
6. Document fencing timeout tuning parameters in `docs/troubleshooting.md`.

## Related PRD Sections

- Section 2.1: The Problem with the Original Module 3 (fakefish-kubevirt fragility)
- Section 2.2: The New Approach (sushy-tools as Redfish emulator)
- Section 3.2: How TNF Works (Pacemaker STONITH mechanism)
- Section 5.2: Demo 1 — Fencing Validation

## References

- [sushy-tools documentation](https://docs.openstack.org/sushy-tools/latest/)
- [fence_redfish man page — fence-agents](https://github.com/ClusterLabs/fence-agents)
- [Two-Node with Fencing — two-node-toolbox](https://github.com/openshift/two-node-toolbox)
- [Red Hat KB: Configuring STONITH in Pacemaker clusters](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_configuring-fencing-configuring-and-managing-high-availability-clusters)
