# Two-Node OpenShift with ODF DRBD Storage

This example extends the `two-node-fencing` deployment with **ODF (OpenShift Data Foundation) using DRBD replication** — providing highly available block storage without a third quorum node.

> **Status**: Demo 5 requires Red Hat Customer Portal access for the installation scripts and dedicated hardware with correctly sized disks. See the [Demo 5 README](../../docs/demos/05-drbd-edge-storage/README.md) and the tracking GitHub issue for progress.

---

## Required Disk Layout (Per Node)

ODF 4.21 two-node DRBD requires **two extra disks per node** beyond the OS disk:

| Disk | Size | Purpose |
|---|---|---|
| `/dev/vda` | 130 GB | OS disk (standard) |
| `/dev/vdb` | **500 GB** (100 GB for dev) | Ceph OSD — raw block device for data storage |
| `/dev/vdc` | **20 GB** | DRBD floating monitor disk — kernel-replicated Ceph monitor data |

### Why Two Extra Disks?

Ceph requires a monitor daemon to maintain cluster state (OSD maps, PG maps, cluster topology). On a two-node cluster, Ceph cannot form a 3-monitor quorum. The ODF TNF solution uses DRBD to replicate a single monitor's disk between both nodes at the kernel level. If one node is fenced, DRBD promotes the secondary copy and the monitor restarts on the survivor — maintaining quorum with a single monitor.

The **OSD disk** (`/dev/vdb`) is entirely separate: it holds the actual data and does not go through DRBD. Only the small monitor disk (`/dev/vdc`) needs DRBD replication.

---

## Deploy

```bash
# From the repo root — add ODF_DISK_SIZE=500 to create /dev/vdb on each node
# Note: /dev/vdc (floating monitor) must be added separately or via virsh attach-disk
sudo env \
  ODF_DISK_SIZE=500 \
  SITE_CONFIG_DIR=/home/vpcuser/openshift-twonode-guide/examples/two-node-drbd \
  bash scripts/deploy-tnf-kvm.sh \
  --cluster-name twonode \
  --base-domain example.com
```

This creates:
- `twonode-openshift-node1.qcow2` — 130 GB OS disk
- `twonode-openshift-node1-odf.qcow2` — 500 GB ODF OSD disk (`/dev/vdb`)
- Same for node2

After deployment, add the floating monitor disk to each VM:

```bash
# Add 20 GB floating monitor disk to each running VM
for VM in twonode-openshift-node1 twonode-openshift-node2; do
  qemu-img create -f qcow2 /var/lib/libvirt/images/${VM}-mon.qcow2 20G
  virsh attach-disk ${VM} /var/lib/libvirt/images/${VM}-mon.qcow2 \
    vdc --driver qemu --subdriver qcow2 --cache none --persistent
done

# Verify on each node
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
for NODE_IP in 192.168.49.21 192.168.49.22; do
  echo "--- $NODE_IP ---"
  ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@$NODE_IP lsblk
done
# Expected: vda (130G, OS), vdb (500G, OSD), vdc (20G, floating monitor)
```

---

## Install ODF Operator

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

# Apply subscription (channel: stable-4.21)
oc apply -f odf-subscription.yaml

# Wait for all CSVs to reach Succeeded (10-15 minutes)
for i in $(seq 1 30); do
  PENDING=$(oc get csv -n openshift-storage --no-headers 2>/dev/null | grep -v "Succeeded" | grep -v "^$")
  echo "$(date +%H:%M:%S) — Pending: ${PENDING:-none}"
  [[ -z "$PENDING" ]] && echo "✅ All CSVs Succeeded!" && break
  sleep 30
done
```

---

## Continue with Demo 5

After ODF operator is ready, follow the full procedure in [Demo 5 README](../../docs/demos/05-drbd-edge-storage/README.md):

1. Label storage nodes
2. Configure DRBD via `configure-drbd.sh` (from [Red Hat Customer Portal article 7139231](https://access.redhat.com/articles/7139231))
3. Create PVs for OSDs
4. Deploy floating Ceph monitor via `mon-deployment.sh`
5. Create StorageCluster (reference: `storagecluster-drbd.yaml`)
6. Post-installation tuning
