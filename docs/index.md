# Two-Node OpenShift Guide

A bare-metal-first guide for deploying a **Two-Node OpenShift 4.22** cluster using the Agent-Based Installer (ABI), with a complete suite of post-deployment edge workload demos. This repository is a standalone replacement for Module 3 of the [retail-edge-ha-workshop](https://github.com/tosin2013/retail-edge-ha-workshop), providing a stable, hardware-backed path that eliminates the fragility of the original nested KubeVirt approach.

## What This Repository Provides

| Component | Description |
|---|---|
| [Architecture Guide](architecture.md) | TNF vs TNA topology decisions, Pacemaker/STONITH, etcd-outside-cluster model |
| [Deployment Guide](deployment-guide.md) | Step-by-step ABI deployment for bare metal and KVM environments |
| [Troubleshooting Guide](troubleshooting.md) | Common failure modes and remediation |
| [Configuration Templates](https://github.com/tosin2013/openshift-twonode-guide/tree/main/examples/two-node-fencing) | Ready-to-use `cluster.yml` and `nodes.yml` for `openshift-agent-install` |
| [Demo 1: Fencing Validation](demos/01-fencing-validation/README.md) | HA chaos test — hard node failure + Pacemaker STONITH |
| [Demo 2: Database HA](demos/02-database-ha/README.md) | PostgreSQL StatefulSet survives planned and unplanned node failure |
| [Demo 3: OpenShift Virtualization](demos/03-openshift-virtualization/README.md) | Legacy VM HA on a two-node cluster |
| [Demo 4: Edge AI Inference](demos/04-edge-ai-inference/README.md) | Lightweight object detection inference at the edge |
| [Demo 5: DRBD Edge Storage](demos/05-drbd-edge-storage/README.md) | Replicated block storage via ODF + DRBD (Developer Preview) |

## Validated Deployment

This guide has been end-to-end validated on OCP 4.22 in a KVM environment on IBM Cloud:

![OpenShift Console — both nodes Ready](assets/console-nodes-ready.png)

Both control-plane nodes `Ready`, all 35 cluster operators `Available`, Pacemaker fencing active. See [kvm-developer-guide.md](kvm-developer-guide.md) for the full IBM Cloud deployment walkthrough.

## Architecture in 60 Seconds

This repository targets the **Two-Node with Fencing (TNF)** topology: exactly two physical servers, no arbiter, no third node. High availability is achieved through:

- **Pacemaker + Corosync** managing cluster membership and resource failover
- **STONITH via Redfish BMC** (`fence_redfish`) — when a node fails, Pacemaker powers it off via its BMC before the surviving node takes over, preventing split-brain
- **etcd running as a Podman container** outside the OpenShift pod lifecycle, managed by Pacemaker — the surviving node promotes etcd to a single-member cluster until the fenced node recovers

For a full explanation including the TNF vs TNA comparison, see [architecture.md](architecture.md).

## Quick Start

### Prerequisites

- A bastion host with `ansible`, `openshift-install`, `oc`, and `git`
- Two physical servers (or KVM VMs) with Redfish-capable BMCs (or `sushy-tools` for KVM)
- Pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)

### 1. Clone this repository and the upstream tooling

```bash
git clone https://github.com/tosin2013/openshift-agent-install
git clone https://github.com/YOUR_ORG/openshift-twonode-guide

# Copy the two-node-fencing example into the openshift-agent-install clusters directory
cp -r openshift-twonode-guide/examples/two-node-fencing openshift-agent-install/clusters/
```

### 2. Edit the configuration templates

```bash
cd openshift-agent-install/clusters/two-node-fencing

# Edit cluster.yml: set your cluster name, domain, pull secret, and SSH key
vi cluster.yml

# Edit nodes.yml: set each node's MAC address, IP, and BMC address
vi nodes.yml
```

See [deployment-guide.md](deployment-guide.md) for the full parameter reference.

### 3. Generate manifests and create the installation ISO

```bash
cd openshift-agent-install
ansible-playbook playbooks/create-manifests.yml -e cluster_name=two-node-fencing
```

### 4. Boot the nodes

- **Bare metal**: Mount the ISO via virtual media through each node's BMC
- **KVM**: `virsh change-media <vm> <device> /path/to/agent.x86_64.iso --config`

### 5. Monitor installation

```bash
openshift-install agent wait-for bootstrap-complete --dir=clusters/two-node-fencing/
openshift-install agent wait-for install-complete --dir=clusters/two-node-fencing/
```

### 6. Validate the cluster

```bash
export KUBECONFIG=clusters/two-node-fencing/auth/kubeconfig
oc get nodes
oc get clusteroperators
pcs status          # SSH to either node to verify Pacemaker cluster health
```

For detailed post-install validation including etcd and Pacemaker checks, see [deployment-guide.md](deployment-guide.md).

## Running the Demos

The demos are designed to be run sequentially (each builds on a healthy cluster from the previous), but each is also independently executable.

```
docs/demos/
├── 01-fencing-validation/   ← Start here — proves the cluster's HA foundation works
├── 02-database-ha/          ← Stateful PostgreSQL workload through planned and unplanned failure
├── 03-openshift-virtualization/  ← Legacy VM HA alongside containers
├── 04-edge-ai-inference/    ← Object detection inference at the edge
└── 05-drbd-edge-storage/    ← Replicated block storage (Developer Preview)
```

Each demo directory contains a `README.md` with objectives, prerequisites, step-by-step instructions, and expected validation output.

## KVM Development Environment

You do not need physical bare-metal servers to work with this repository. Using KVM with `sushy-tools` as a Redfish emulator, you can run the full deployment and all demos on a single host machine. The automated deployment script handles everything end-to-end — including the IBM Cloud NAT path, Route53 DNS, HAProxy, and an etcd quorum recovery step that resolves a deterministic 2-node bootstrap race condition.

See **[kvm-developer-guide.md](kvm-developer-guide.md)** for the full step-by-step guide.

```bash
# One-command deployment (IBM Cloud KVM path)
sudo bash scripts/deploy-tnf-kvm.sh
```

!!! note "Required host resources"
    32 GB RAM minimum (64 GB recommended), 400 GB free disk, CPU with VT-x/AMD-V.

## Upstream Dependencies

| Repository | Role |
|---|---|
| [tosin2013/openshift-agent-install](https://github.com/tosin2013/openshift-agent-install) | ABI automation framework — this repo adds the `two-node-fencing` example |
| [openshift/two-node-toolbox](https://github.com/openshift/two-node-toolbox) | Pacemaker resource configuration for TNF post-install |
| [tosin2013/retail-edge-ha-workshop](https://github.com/tosin2013/retail-edge-ha-workshop) | Original Module 3 — this repo is its replacement |

## Architecture Decisions

Key decisions made in this repository are documented as Architecture Decision Records in [`adrs/`](adrs/001-tnf-topology-selection.md):

| ADR | Decision |
|---|---|
| [ADR-001](adrs/001-tnf-topology-selection.md) | TNF topology selected over TNA |
| [ADR-002](adrs/002-agent-based-installer.md) | Agent-Based Installer via `openshift-agent-install` |
| [ADR-003](adrs/003-bmc-redfish-fencing-strategy.md) | `fence_redfish` for bare metal, `sushy-tools` for KVM |
| [ADR-004](adrs/004-etcd-outside-cluster.md) | etcd managed by Pacemaker outside the cluster |
| [ADR-005](adrs/005-local-storage-over-odf-ceph.md) | LVM/TopoLVM for storage; ODF+DRBD is Developer Preview only |
| [ADR-006](adrs/006-ovnkubernetes-network-plugin.md) | OVNKubernetes required for TNF |
| [ADR-007](adrs/007-kvm-sushy-tools-dev-environment.md) | KVM + sushy-tools for development parity |

## Target Audience

- **Edge Infrastructure Architects** — reference architecture for resilient OpenShift at retail stores, manufacturing floors, and remote sites with only two servers
- **OpenShift Administrators** — step-by-step deployment and validation guide
- **Platform Engineers and Developers** — post-deployment demos validating edge workload behavior under node failure

## OpenShift Version

This guide targets **OpenShift Container Platform 4.22** with the TNF topology (Technology Preview). The `featureSet: TechPreviewNoUpgrade` flag is required and means upgrade requires reinstallation. For a production-ready, upgradable path on 3 nodes, see the TNA topology note in [architecture.md](architecture.md).
