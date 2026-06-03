# 007. KVM + sushy-tools as the Development and Testing Environment

**Status**: Accepted
**Date**: 2026-06-02
**Domain**: development-environment / testing-infrastructure

## Context

The project requires a development environment where:
1. The full two-node cluster deployment can be tested end-to-end without physical bare-metal servers.
2. Fencing (STONITH via Redfish) can be exercised realistically — not mocked.
3. The development machine (referenced in the PRD) is available for KVM-based workloads.
4. The environment faithfully simulates production bare-metal behavior to ensure the deployment guide is accurate.

The PRD specifically notes that the development machine can be used via KVM and references `sushy-tools` as the Redfish emulator (see Section 2.2). The PRD also notes use of `lsblk` to verify available storage for KVM disk images.

The rejected alternative — nested KubeVirt VMs on an OpenShift hub cluster with fakefish-kubevirt — was the root cause of Module 3's failure. That approach introduced:
- MAC address regeneration on VM restart (breaking ABI static network config).
- Nested virtualization performance degradation.
- UDN network unreachability (blocking `wait-for install-complete`).
- Dependence on a fully functional RHACM hub cluster to test edge deployments.

## Decision

Use **KVM (libvirt/QEMU) on the local development machine** with **sushy-tools (`sushy-emulator`)** as the Redfish API layer.

Architecture of the development environment:

```
Development Host (this machine)
├── libvirt / QEMU
│   ├── VM: openshift-node1 (control-plane-0)
│   └── VM: openshift-node2 (control-plane-1)
├── sushy-tools (sushy-emulator)
│   └── Exposes Redfish API on http://localhost:8000
│       ├── /redfish/v1/Systems/[node1-uuid]/  → maps to VM openshift-node1
│       └── /redfish/v1/Systems/[node2-uuid]/  → maps to VM openshift-node2
└── Bastion functions (openshift-install, oc, pcs, fence_redfish)
    └── Same host or separate VM with access to cluster network
```

The KVM VMs are assigned **static MAC addresses** in the libvirt XML definition. These MAC addresses are used in `examples/two-node-fencing/nodes.yml` — this matches the production bare-metal pattern where MAC addresses are physically fixed.

sushy-tools maps Redfish `ResetType` actions (e.g., `ForceOff`, `On`) to `virsh` power commands, providing genuine power-state semantics rather than OS-level simulation.

The `icm` CLI (referenced in the PRD) is used for memory management on the development host, ensuring sufficient RAM is available for the two KVM VMs running OCP control-plane nodes.

## Consequences

**Positive:**
- Eliminates all fragility from the original nested-KubeVirt approach.
- Static MACs in libvirt XML definitions are stable across VM restarts — solves the root cause of Module 3 MAC regeneration failures.
- sushy-tools is actively maintained by the OpenStack Ironic project and provides a standard Redfish implementation.
- The development environment can be set up on a single physical host — no additional hardware required.
- `fence_redfish` commands used in development work identically on bare metal (only IP addresses and credentials differ).
- KVM provides near-native CPU performance (hardware virtualization via KVM), adequate for OCP control-plane workloads.

**Negative:**
- KVM requires the development host to have VT-x/AMD-V hardware virtualization enabled and sufficient RAM (minimum ~32 GB recommended for 2 OCP control-plane VMs + host OS).
- sushy-tools must be started before ABI deployment and kept running throughout installation; this is a manual prerequisite step.
- Network bridging on the KVM host must be configured to give the VMs routable IPs accessible from the bastion — this varies by Linux distribution and host network configuration.
- Performance of OCP workloads inside KVM VMs is lower than bare metal; Demo 4 (Edge AI inference) may have limited throughput in KVM.
- No GPU passthrough in the default development environment — AI inference demos run on CPU only unless GPU passthrough is configured separately.

## Domain Considerations

- **Resource planning**: Use `lsblk` to verify available disk space for KVM image files before creating VMs. OCP control-plane nodes require a minimum 120 GB disk each (recommended 200 GB for full demo suite).
- **`icm` CLI**: Use `icm --help` to check available memory and manage memory allocation for the KVM VMs. Document the minimum host RAM requirement.
- **sushy-tools port**: Default port 8000; this becomes the `bmc.address` in `nodes.yml` as `redfish-virtualmedia://localhost:8000/redfish/v1/Systems/[uuid]`.
- **libvirt network**: A dedicated libvirt network (NAT or bridged) for the cluster network should be created to isolate cluster traffic.

## Implementation Plan

1. Document KVM host prerequisites (CPU virtualization, RAM, disk) in `docs/deployment-guide.md`.
2. Provide `lsblk` and `free -h` commands in the prerequisites checklist.
3. Document `icm --help` usage for memory verification.
4. Provide sushy-tools installation commands (pip install or container) and the `sushy-emulator` configuration file.
5. Document libvirt VM creation with static MAC addresses for both nodes.
6. Provide the sushy-tools → libvirt VM UUID mapping procedure.
7. Document how to construct the `bmc.address` Redfish URL from the sushy-tools endpoint and VM UUID.
8. Include a "KVM vs Bare Metal" comparison table in `docs/deployment-guide.md` showing which steps differ.

## Related PRD Sections

- Section 2.2: The New Approach (KVM with sushy-tools)
- Section 5 (header note): Development via KVM, `lsblk` for disk, `icm` CLI for memory

## References

- [sushy-tools (sushy-emulator) documentation](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html)
- [libvirt documentation](https://libvirt.org/docs.html)
- [OpenShift Agent-Based Installer — Hardware requirements](https://docs.openshift.com/container-platform/4.22/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html#agent-install-hardware-requirements_preparing-to-install-with-agent-based-installer)
