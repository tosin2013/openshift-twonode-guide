# IBM Cloud Hardware Specification — Two-Node OpenShift TNF

This document recommends specific IBM Cloud bare-metal server profiles for deploying
the Two-Node OpenShift with Fencing (TNF) cluster from this repository, including
running all five demo workloads.

---

## Quick Reference

| Profile | vCPU | RAM | Boot Disk | Extra Disks | Suitable For |
|---------|------|-----|-----------|-------------|--------------|
| **bx2-metal-32x128** _(recommended)_ | 32 | 128 GB | 1× 960 GB NVMe | 2× 960 GB NVMe | All 5 demos including ODF+DRBD |
| bx2-metal-16x64 _(minimum)_ | 16 | 64 GB | 1× 960 GB NVMe | 1× 960 GB NVMe | Demos 1–4 only (no ODF) |
| bx2-metal-48x192 _(large)_ | 48 | 192 GB | 2× 960 GB NVMe | 2× 960 GB NVMe | ODF+DRBD with margin for production loads |

> **Note**: IBM Cloud bare-metal profiles and availability change over time.
> Always verify current profiles at [cloud.ibm.com/gen1/infrastructure/bare-metal/provision](https://cloud.ibm.com/gen1/infrastructure/bare-metal/provision).
> Profile names above use the VPC Gen2 naming convention as of June 2026.

---

## Recommended Profile: bx2-metal-32x128

### Specification

| Resource | Value | Why It Matters |
|----------|-------|----------------|
| CPU | 32 vCPU (Intel Cascade Lake or Ice Lake) | ODF/Ceph daemons (mon, OSD, MDS) each consume 1–4 vCPU under load; 32 vCPU provides headroom for all daemons + OpenShift system pods |
| RAM | 128 GB | ODF recommends ≥ 64 GB for each node; 128 GB accommodates Ceph mon (2 GB), OSD (4 GB × 2), MDS (2 GB), plus OpenShift control-plane overhead (~12 GB) |
| Boot / OS disk | 1× 960 GB NVMe SSD | Holds RHCOS, OpenShift state, container image cache, and etcd WAL. NVMe is critical for etcd fsync latency (must be < 10ms at P99) |
| etcd disk | Separate partition on boot NVMe | A dedicated `/var/lib/etcd` partition isolates etcd I/O from container image writes |
| OSD disks | 2× 960 GB NVMe SSD | Each node contributes one OSD disk to DRBD replication; 2 disks allow one spare |
| Network | 2× 10 GbE (public + private) | DRBD replication and Ceph OSD traffic should run on the private 10 GbE interface; keep public traffic separate |
| BMC | IPMI over LAN (IBM Cloud provides this via the management network) | Required for `fence_redfish` or `fence_ipmi` STONITH |

### Disk Layout

```
/dev/sda (960 GB NVMe — boot disk)
├── /boot/efi         200 MB
├── /boot             1 GB
├── /                 100 GB   ← RHCOS root
├── /var              200 GB   ← container images, kubelet data
├── /var/lib/etcd     50 GB    ← etcd WAL (NVMe, dedicated partition)
└── (remaining)       ~609 GB  ← available for LVM Operator / TopoLVM

/dev/sdb (960 GB NVMe — OSD disk, node 1)
└── Managed by DRBD / Rook-Ceph OSD

/dev/sdc (960 GB NVMe — spare or second OSD)
└── Available for expansion
```

> **Partition etcd separately**: The most common cause of TNF instability is etcd
> sharing I/O with container image pulls or log rotation. A dedicated partition
> eliminates this competition.

---

## Minimum Profile: bx2-metal-16x64

Suitable for Demos 1–4 (fencing, database HA, virtualization, edge AI). **Not
sufficient for Demo 5** (ODF + DRBD) due to resource constraints on ODF daemons.

| Resource | Value | Constraint |
|----------|-------|-----------|
| CPU | 16 vCPU | ODF daemons require tuned resource limits (see ADR-009) |
| RAM | 64 GB | Tight; do not run multiple demos simultaneously |
| Boot disk | 1× 960 GB NVMe | Share all workloads on one disk |
| OSD disk | 1× 960 GB NVMe | Only one OSD per node — no redundancy |
| Network | 2× 10 GbE | Same as recommended |

---

## Network Requirements

### Interface Assignment

| Interface | Purpose | Speed |
|-----------|---------|-------|
| `eth0` (public) | Bastion → cluster API access, pull secret traffic | 1 GbE minimum |
| `eth1` (private) | Inter-node cluster traffic (OVNKubernetes, DRBD, Ceph) | 10 GbE required |
| Management NIC | IPMI / Redfish BMC access | Out-of-band (IBM Cloud provides) |

### IP Addresses Needed (per deployment)

| Address | Purpose |
|---------|---------|
| 2× node private IPs | Static; set in `examples/two-node-fencing/nodes.yml` |
| 1× API VIP | Floats between nodes; set as `api_vip` in `cluster.yml` |
| 1× Ingress VIP | Floats between nodes; set as `ingress_vip` in `cluster.yml` |
| 1× bastion private IP | For `oc` and SSH access during deployment |

---

## IBM Cloud-Specific Steps

### 1. Order the Servers

Order two identical `bx2-metal-32x128` bare-metal servers in the same IBM Cloud VPC
and availability zone. Identical profiles are important — TNF assumes symmetric
hardware for Pacemaker weight calculations.

```
IBM Cloud Console → VPC Infrastructure → Bare Metal Servers → Create
Profile: bx2-metal-32x128
OS: Red Hat Enterprise Linux CoreOS (select "Bring your own image" — ABI installs RHCOS)
Data volumes: add 2× 960 GB additional volumes during provisioning
```

### 2. Enable IPMI/Redfish Access

IBM Cloud bare-metal servers include an out-of-band management interface accessible
via the private network. Note the IPMI address for each node from the IBM Cloud
console:

```
Console → Bare Metal Servers → <server> → Network → Management IP
```

This address is the value for `bmc.address` in `nodes.yml`:

```yaml
bmc:
  address: "ipmi://<management-ip>"
  username: "root"
  password: "<IPMI password from Cloud console>"
```

For Redfish (preferred over IPMI):

```yaml
bmc:
  address: "redfish://<management-ip>/redfish/v1/Systems/1"
```

Verify Redfish is accessible from the bastion before starting deployment:

```bash
curl -k -u root:<password> \
  https://<management-ip>/redfish/v1/Systems/
```

### 3. KVM on IBM Cloud (Development Path)

If you are using a **single large IBM Cloud bare-metal server** to host both TNF VMs
(development/lab path, not production), the `bx2-metal-48x192` profile is recommended
to host two 16-vCPU / 64 GB KVM VMs with headroom for the host OS:

```
KVM Host: bx2-metal-48x192  (48 vCPU, 192 GB RAM)
├── VM: openshift-node1  (16 vCPU, 64 GB RAM, 200 GB boot, 100 GB OSD)
└── VM: openshift-node2  (16 vCPU, 64 GB RAM, 200 GB boot, 100 GB OSD)
  (Host overhead: ~16 vCPU, 64 GB RAM for hypervisor + bastion workloads)
```

This matches the validated configuration used during the development of this
repository. See [docs/kvm-developer-guide.md](kvm-developer-guide.md) for the
full IBM Cloud KVM deployment walkthrough.

---

## Pre-Deployment Hardware Validation

Run these checks on each bare-metal node before starting the ABI deployment:

```bash
# Verify NVMe disk count and model
lsblk -d -o NAME,SIZE,MODEL,ROTA
# ROTA=0 confirms NVMe/SSD; expect 3 disks per node

# Baseline etcd disk latency (must be < 10ms P99)
# Install fio: dnf install -y fio
fio --rw=write --ioengine=sync --fdatasync=1 --directory=/var/lib/etcd \
    --size=22m --bs=2300 --name=etcd-test
# Look for: sync lat (nsec): p99 < 10000000 (10ms)

# Verify IPMI/Redfish reachability from bastion
fence_redfish -a <management-ip> -l root -p <password> \
  -b "/redfish/v1/Systems/1" -o status
# Expected: Status: ON

# Verify VT-x / AMD-V (for KVM path only)
grep -c vmx /proc/cpuinfo
# Expected: > 0
```

---

## Cost Estimate (as of June 2026)

> Prices are approximate IBM Cloud on-demand rates in USD. Reserved instances
> reduce cost by 30–50%.

| Configuration | Profile | Nodes | Est. Monthly |
|---------------|---------|-------|-------------|
| Bare-metal TNF (full demos) | bx2-metal-32x128 | 2 | ~$1,800–$2,400 |
| Bare-metal TNF (demos 1–4 only) | bx2-metal-16x64 | 2 | ~$900–$1,200 |
| KVM dev on single host | bx2-metal-48x192 | 1 | ~$1,200–$1,500 |
| Bastion (VSI, 4 vCPU, 16 GB) | bx2-4x16 | 1 | ~$50 |

**For development**: use the KVM path on a single `bx2-metal-48x192` host (~$1,300/mo)
rather than two separate bare-metal servers. This is the configuration used during
development of this repository.

**For production demos or customer-facing validation**: use two `bx2-metal-32x128`
servers to faithfully represent a real edge deployment.

---

## Related Resources

- [Architecture Guide §7 — Node Hardware Requirements](architecture.md#7-node-hardware-requirements)
- [KVM Developer Guide](kvm-developer-guide.md) — full IBM Cloud KVM deployment walkthrough
- [Deployment Guide §3 — Bare Metal Environment Setup](deployment-guide.md#3-bare-metal-environment-setup)
- [ADR-007 — KVM + sushy-tools Dev Environment](adrs/007-kvm-sushy-tools-dev-environment.md)
