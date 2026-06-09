# Demo 5: DRBD Edge Storage — Developer Preview

**Objective**: Demonstrate highly available block storage for the two-node cluster using ODF 4.21 with DRBD, enabling stateful workloads to survive a node failure without requiring a third node for Ceph quorum.

> ## ⚠ Developer Preview Warning
>
> **ODF on Two-Node OpenShift with Fencing using DRBD is a Developer Preview feature as of ODF 4.21.**
>
> Developer Preview features:
> - Are **not supported** for production use
> - May contain bugs or incomplete functionality
> - Are subject to change or removal without notice
> - Do not qualify for Red Hat production support
>
> For assistance, contact: `ocs-devpreview@redhat.com`
>
> The following ODF features are **NOT available** in this configuration:
> - **NooBaa** (object storage / S3-compatible API)
> - **NFS server** export via ODF
> - **RGW (RADOS Gateway / S3)**
> - **Regional Disaster Recovery / Metro-DR**
> - Multi-cluster storage federation, PDBs, Mon failover, Multus
>
> This demo is provided for evaluation and proof-of-concept purposes only.
> For production storage on two-node clusters, use the LVM Operator (see [Demo 2](../02-database-ha/README.md)).

---

## Architecture Overview

### Why DRBD? The Two-Node Ceph Problem

Standard Ceph requires a **minimum of 3 monitors** to maintain quorum. On a two-node cluster, if one node goes down, the remaining Ceph monitor cannot form a majority and the entire storage cluster stalls. This is the fundamental storage HA gap in the two-node OpenShift architecture.

ODF 4.21 solves this with a **floating Ceph monitor** backed by DRBD:

```
Node 1                                     Node 2
┌───────────────────────────────────────┐  ┌───────────────────────────────────────┐
│                                       │  │                                       │
│  /dev/vdb (100–500 GB)                │  │  /dev/vdb (100–500 GB)                │
│  ┌─────────────────────────────┐      │  │  ┌─────────────────────────────┐      │
│  │   Ceph OSD (local PV)       │      │  │  │   Ceph OSD (local PV)       │      │
│  └─────────────────────────────┘      │  │  └─────────────────────────────┘      │
│                                       │  │                                       │
│  /dev/vdc (≥ 10 GB)  ◄───DRBD────►   │  │  /dev/vdc (≥ 10 GB)                  │
│  ┌─────────────────────────────┐      │  │  ┌─────────────────────────────┐      │
│  │  DRBD device /dev/drbd0     │      │  │  │  DRBD device /dev/drbd0     │      │
│  │  Floating Ceph Monitor      │      │  │  │  (standby — synced in real   │      │
│  │  (Active — mon data here)   │      │  │   time via DRBD protocol C)   │      │
│  └─────────────────────────────┘      │  └─────────────────────────────────┘     │
└───────────────────────────────────────┘  └───────────────────────────────────────┘
                              ▲
                              │ DRBD replicates mon data at kernel level
                              │ (port 7794 between nodes)
                              ▼
                   When Node 1 is fenced:
                   - DRBD promotes /dev/drbd0 on Node 2 to Primary
                   - Floating Ceph mon is restarted on Node 2
                   - Ceph quorum is maintained with 1 monitor
                   - OSD on Node 2 is healthy → PVCs remain accessible
```

### Why the Disk Sizes Matter

| Disk | Purpose | Minimum Size | Why |
|---|---|---|---|
| `/dev/vdb` (OSD disk) | Ceph OSD — raw block device for storing actual data | **500 GB** (production) | Ceph OSDs require significant capacity for metadata, BlueStore WAL/DB journals, and data. Below 500 GB, OSD performance degrades and the `osd_min_size` check may reject the disk. For dev/testing, 100 GB may work but is not recommended. |
| `/dev/vdc` (floating monitor disk) | DRBD-replicated block device for the Ceph monitor | **10–50 GB** | Ceph monitor data (cluster maps, OSD maps, PG maps) is small — typically a few GB. 10 GB is sufficient. DRBD protocol C (synchronous) means writes commit only when both nodes acknowledge, requiring very low latency between nodes. |

### Why DRBD Instead of a Third Node for the Monitor?

A third node (arbiter) would solve the quorum problem but increases hardware cost. DRBD provides synchronous block-level replication of the monitor's disk, so:

- The monitor disk **always exists on both nodes simultaneously**
- If the active node is fenced, DRBD promotes the secondary's copy to primary in seconds
- The Ceph monitor is restarted on the surviving node using its local DRBD copy
- **No quorum loss** — the cluster sees the same monitor with the same data

This is specifically designed for **edge deployments** where a third node is impractical.

### KMM (Kernel Module Management)

RHCOS (Red Hat CoreOS) is an immutable OS — you cannot install RPMs directly. The DRBD kernel module must be compiled and loaded via the **Kernel Module Management (KMM) operator**, which:

1. Pulls the DRBD source
2. Builds a kernel module in-cluster using the exact running kernel version
3. Loads the module on both nodes via a DaemonSet
4. Rebuilds the module after kernel updates automatically

---

## Infrastructure Requirements

> **Note**: This demo requires dedicated hardware that differs from the standard two-node deployment.
> A GitHub issue tracks the work to validate this demo on properly-sized hardware:
> **[GitHub Issue #6 — Demo 5: Validate ODF 4.21 DRBD Edge Storage on properly-sized hardware](https://github.com/tosin2013/openshift-twonode-guide/issues/6)**

### Per-Node Disk Layout

```
/dev/vda   ← OS disk (130 GB minimum, standard)
/dev/vdb   ← Ceph OSD disk (500 GB minimum for production, 100 GB for dev)
/dev/vdc   ← DRBD floating monitor disk (10–50 GB, ≥ 10 GB required)
```

### Network Requirements

- Port **7794** must be open and reachable between nodes (DRBD replication)
- DRBD protocol C (synchronous) requires low latency (< 1 ms RTT recommended)

### How to Deploy the Cluster with ODF Disks

Use the `deploy-tnf-kvm.sh` script with both `ODF_DISK_SIZE` and an additional `DRBD_MON_DISK_SIZE` variable (see `examples/two-node-drbd/`):

```bash
# Standard two-node with ODF OSD disk (100 GB for dev, 500 GB for production)
# and floating monitor disk (20 GB)
export KUBECONFIG=/dev/null  # cleared before deploy

nohup sudo env \
  ODF_DISK_SIZE=500 \
  SITE_CONFIG_DIR=/home/vpcuser/openshift-twonode-guide/examples/two-node-drbd \
  bash scripts/deploy-tnf-kvm.sh \
  --cluster-name twonode \
  --base-domain example.com \
  > /tmp/deploy.log 2>&1 &
```

After deployment, verify ODF disks are present:

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
ssh -i $SSH_KEY core@192.168.49.21 lsblk
# Expected:
# NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
# vda    252:0    0  130G  0 disk
# ├─vda1 252:1    0    1M  0 part
# ...
# vdb    252:16   0  500G  0 disk   ← OSD disk
# vdc    252:32   0   20G  0 disk   ← Floating monitor disk (add manually or via script)
```

---

## Installation Procedure

> **Important**: This procedure requires Red Hat Customer Portal access to download the installation scripts
> referenced in the [ODF 4.21 Two-Node Fencing Developer Preview article](https://access.redhat.com/articles/7139231).
> The scripts are: `configure-drbd.sh`, `mon-deployment.sh`, `lso-storageclass.yml`, `pv.yml`, and `update-csi-resources.sh`.

### Step 1: Install the ODF Operator

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

oc apply -f examples/two-node-drbd/odf-subscription.yaml
# channel: stable-4.21

# Wait for all CSVs to reach Succeeded (10-15 minutes)
for i in $(seq 1 30); do
  PENDING=$(oc get csv -n openshift-storage --no-headers 2>/dev/null | grep -v "Succeeded" | grep -v "^$")
  echo "$(date +%H:%M:%S) — Pending CSVs: ${PENDING:-none}"
  [[ -z "$PENDING" ]] && echo "✅ All CSVs Succeeded!" && break
  sleep 30
done
```

Expected CSVs that must reach `Succeeded`:
- `odf-operator.v4.21.x`
- `ocs-operator.v4.21.x`
- `rook-ceph-operator.v4.21.x`
- `odf-prometheus-operator.v4.21.x`
- `mcg-operator.v4.21.x`
- `odf-csi-addons-operator.v4.21.x`
- `odf-dependencies.v4.21.x`
- `ocs-client-operator.v4.21.x`

### Step 2: Label Storage Nodes

```bash
# Label both nodes as ODF storage nodes
oc label node openshift-node1 cluster.ocs.openshift.io/openshift-storage=''
oc label node openshift-node2 cluster.ocs.openshift.io/openshift-storage=''

# Verify
oc get nodes --show-labels | grep openshift-storage
```

### Step 3: Configure DRBD (Floating Monitor Disk)

This step uses the `configure-drbd.sh` script from the [Red Hat Customer Portal article](https://access.redhat.com/articles/7139231).
Download and run it from a host with `oc` access:

```bash
# The script installs KMM operator and configures DRBD on the floating monitor disk
# Replace /dev/vdc with your actual floating monitor disk device
bash configure-drbd.sh --floating-mon-disk /dev/vdc
```

What the script does internally:
1. Installs the KMM (Kernel Module Management) operator
2. Creates a `Module` CR to build the `drbd` kernel module for the running RHCOS kernel
3. Waits for KMM to compile and load the module on both nodes (~10 minutes)
4. Configures `/etc/drbd.conf` and `/etc/drbd.d/r0.res` via a MachineConfig
5. Initializes the DRBD resource on the floating monitor disk (port 7794)

Verify DRBD is configured:

```bash
NODE=openshift-node1
oc debug node/${NODE} -- chroot /host \
  sudo podman run --rm --privileged \
  -v /dev:/dev -v /etc/drbd.conf:/etc/drbd.conf -v /etc/drbd.d:/etc/drbd.d \
  --net host --hostname "${NODE}" \
  quay.io/rhceph-dev/odf4-drbd-rhel9:v4.21.0-1 \
  drbdadm status
# Expected:
# r0 role:Secondary
#   disk:UpToDate
# openshift-node2 role:Secondary
#   peer-disk:UpToDate
```

### Step 4: Create PVs for OSD Disks

Create the Local Storage StorageClass and PVs using the scripts from the Customer Portal article:

```bash
# Create local storage StorageClass (lso-storageclass.yml from Customer Portal)
oc create -f lso-storageclass.yml

# Edit pv.yaml to match your disk path and size, then apply for both nodes
# Example: /dev/vdb, 500Gi, nodeAffinity to openshift-node1 and openshift-node2
oc create -f pv.yml
```

Alternatively, create the PVs manually using disk-by-id:

```bash
# Get disk IDs on each node
ssh -i ~/.ssh/openshift-twonode-ed25519 core@192.168.49.21 \
  ls -la /dev/disk/by-id/ | grep -v part
```

```yaml
# pv-node1.yaml — repeat for node2
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-odf-node1
spec:
  capacity:
    storage: 500Gi
  volumeMode: Block
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage-odf
  local:
    path: /dev/disk/by-id/<DISK_ID_OF_VDB_ON_NODE1>
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - openshift-node1
```

### Step 5: Deploy the Floating Monitor

Run the `mon-deployment.sh` script from the Customer Portal article:

```bash
# Edit mon-deployment.sh to use the downstream Ceph image, then run:
bash mon-deployment.sh

# Verify the floating monitor deployment
oc get deployment -n openshift-storage | grep rook-ceph-mon-c
oc get svc -n openshift-storage | grep mon
```

### Step 6: Create the StorageCluster

Apply the `storagecluster.yaml` from the Customer Portal article:

```bash
# The StorageCluster CR is provided in the Customer Portal article
# as storagecluster.yaml — apply it:
oc create -f storagecluster.yaml

# Wait for Ready status (15-30 minutes)
oc get storagecluster -n openshift-storage -w
```

Also available in `examples/two-node-drbd/storagecluster-drbd.yaml` as a reference.
The StorageCluster CR references the local-storage-odf StorageClass and sets `replica: 2`.

### Step 7: Post-Installation Tuning

On a two-node KVM host, ODF's CSI controller pods request more CPU than is
available on a heavily-loaded control-plane node — causing `rook-ceph-mon-a`,
`rook-ceph-osd-1`, and `rook-ceph-mds-a` to stay `Pending` indefinitely.
This script caps the CSI driver CPU/memory requests so the remaining ODF pods
can schedule. **This must be run before the Demo Validation fence test.**

```bash
# Run from the repository root
bash scripts/update-csi-resources.sh
```

Verify the tuning freed capacity and the Pending pods scheduled:

```bash
# Wait up to 5 minutes for all ODF pods to reach Running
watch -n10 "oc get pods -n openshift-storage --no-headers | grep -v Running | grep -v Completed"
# Expected: no output (all pods Running or Completed)

# Confirm Ceph is still healthy after the restart
oc get cephcluster -n openshift-storage \
  -o jsonpath='Ceph health: {.items[0].status.ceph.health}{"\n"}'
# Expected: Ceph health: HEALTH_OK

# Confirm both OSDs are now up (need 2 OSDs for full replica protection)
oc get pods -n openshift-storage --no-headers | grep "rook-ceph-osd"
# Expected: rook-ceph-osd-0 Running, rook-ceph-osd-1 Running
```

### Step 8: Verify the StorageClasses

```bash
oc get storageclass
# Expected:
# ocs-storagecluster-ceph-rbd   (block, RWO — primary for most workloads)
# ocs-storagecluster-cephfs     (file, RWX — if available in this config)
```

---

## Demo Validation (After Successful Installation)

### Write Test Data

```bash
# Create a PVC backed by ODF/DRBD StorageClass
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: drbd-test-pvc
  namespace: default
spec:
  storageClassName: ocs-storagecluster-ceph-rbd
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF

oc get pvc drbd-test-pvc -n default -w
# Wait until STATUS=Bound

# Write test data
oc run drbd-writer --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "drbd-writer",
      "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
      "command": ["sh", "-c",
        "echo \"DRBD test - $(date)\" > /mnt/test.txt && sha256sum /mnt/test.txt && cat /mnt/test.txt"],
      "volumeMounts": [{"name":"data","mountPath":"/mnt"}]
    }],
    "volumes": [{"name":"data","persistentVolumeClaim":{"claimName":"drbd-test-pvc"}}]
  }
}'

oc logs drbd-writer -n default
# Record the SHA256 checksum for later verification
```

### Fence Node 1 and Verify Failover

> ⚠ **Critical order for 2-node TNF**: Always use `pcs node fence` BEFORE applying
> `out-of-service` taints. Applying taints to a live node triggers the etcd-operator to
> remove it from the etcd member list. On a 2-node cluster this causes `panic: removed all voters`
> → complete API outage. See [011](../../adrs/011-odf-tnf-demo5-fencing-procedure.md)
> for full explanation and recovery procedure.

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# --- Pre-flight: run the 7-signal health check before any fencing operation ---
# All checks (quorum, etcd, API, operators, STONITH, ODF) must pass before proceeding.
# A failing pre-flight here means the subsequent fence will likely cause an unrecoverable
# API outage rather than a clean failover.
bash scripts/tnf-preflight-validate.sh
# Expected: "Pre-flight complete: N/N checks passed. Safe to proceed."

# Check which node the PVC is bound to
PVC_NODE=$(oc get pods -n default -o wide | grep drbd-writer | awk '{print $7}')
echo "PVC was on: ${PVC_NODE}"

# --- Step 1: Fence Node 1 via Pacemaker STONITH (powers off via Redfish) ---
# This MUST happen before applying taints — see ADR-004.
ssh -i $SSH_KEY core@192.168.49.22 \
  sudo pcs node fence openshift-node1

# Wait for node to go NotReady
echo "Waiting for openshift-node1 to go NotReady..."
for i in $(seq 1 12); do
  STATUS=$(oc get node openshift-node1 --no-headers 2>/dev/null | awk '{print $2}')
  echo "$(date +%H:%M:%S) openshift-node1 status=$STATUS"
  [[ "$STATUS" == "NotReady" ]] && break
  sleep 10
done

# --- Step 2: Apply out-of-service taints (ONLY after node is confirmed powered off) ---
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule

# Watch node status
oc get nodes -w

# Verify DRBD promoted on survivor
ssh -i $SSH_KEY core@192.168.49.22 \
  sudo drbdadm status
# Expected: Node 2 shows role:Primary, disk:UpToDate

# Read back the data on the survivor
oc run drbd-reader --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "drbd-reader",
      "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
      "command": ["sh", "-c",
        "cat /mnt/test.txt && sha256sum /mnt/test.txt"],
      "volumeMounts": [{"name":"data","mountPath":"/mnt"}]
    }],
    "volumes": [{"name":"data","persistentVolumeClaim":{"claimName":"drbd-test-pvc"}}]
  }
}'

oc logs drbd-reader -n default
# Checksum must match the writer output
```

### Restore Node 1 and Verify Re-sync

```bash
# Power on Node 1 via Pacemaker / BMC
ssh -i $SSH_KEY core@192.168.49.22 \
  sudo pcs node unstandby openshift-node1

# Wait for DRBD re-sync
oc get nodes -w
# Wait until openshift-node1 shows Ready

# Remove the out-of-service taints
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule-

# Verify DRBD re-sync is complete
ssh -i $SSH_KEY core@192.168.49.21 \
  sudo drbdadm status
# Both nodes: disk:UpToDate
```

---

## Expected Results

| Check | Expected Result |
|---|---|
| ODF operator CSVs | All 8 CSVs in `Succeeded` state |
| StorageCluster status | `Ready` |
| DRBD status (healthy) | Both nodes: `disk:UpToDate` |
| PVC after node failure | Accessible from surviving node via DRBD promotion |
| Test file content after failover | Identical to pre-failover write |
| Checksum verification | Matches — data integrity confirmed |
| DRBD re-sync after node recovery | Both nodes return to `UpToDate` |

---

## Troubleshooting

### DRBD build in error state (KMM build fails)

```bash
oc get pods -n openshift-kmm
# If drbd-kmod-build pod shows Error:

oc delete module drbd-kmod -n openshift-kmm
oc delete pods -n openshift-kmm -l app=drbd-kmod-build

# Re-run configure-drbd.sh to trigger a fresh module build
```

### Floating monitor enters drbd-init failover state

```bash
# Manually set both nodes to DRBD Secondary to reset role state
for NODE in openshift-node1 openshift-node2; do
  oc debug node/${NODE} -- chroot /host \
    sudo podman run --rm --privileged \
    -v /dev:/dev -v /etc/drbd.conf:/etc/drbd.conf -v /etc/drbd.d:/etc/drbd.d \
    --hostname "${NODE}" \
    quay.io/rhceph-dev/odf4-drbd-rhel9:v4.21.0-1 \
    drbdadm secondary r0
done
```

### Registry pod restarts cause DRBD DaemonSet restart

```bash
# Patch NodeModulesConfig CR for each node to force KMM module rebuild
oc get nodemodulesconfig.kmm.sigs.x-k8s.io

for NODE in openshift-node1 openshift-node2; do
  oc patch nodemodulesconfig ${NODE} --type=json --subresource=status \
    -p='[{"op": "remove", "path": "/status/modules/0"}]'
done
```

### etcd panic: "removed all voters" — API completely unresponsive

**Symptom**: `oc` commands time out with `context deadline exceeded` after applying
`out-of-service` taints. This happens when taints were applied to a live node BEFORE
Pacemaker fenced it, causing the etcd-operator to remove the node from etcd membership.

**Check**:
```bash
SSH_KEY=~/.ssh/openshift-twonode-ed25519
# Check etcd Pacemaker status
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -E "etcd|Failed"
# Check etcd podman container exit code on each node
for IP in 192.168.49.21 192.168.49.22; do
  echo "--- $IP ---"
  ssh -i $SSH_KEY core@$IP \
    'sudo podman ps -a --filter "name=etcd" --format "{{.Status}}" 2>&1'
done
```

**Recovery**:
```bash
SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Identify the clean node: "Exited (0) ..." means clean WAL data
# (vs "Exited (2) ..." which means panic/corrupted)

# Step 1: Wipe corrupted etcd member directory on the panic node
ssh -i $SSH_KEY core@<panic-node-ip> sudo rm -rf /var/lib/etcd/member

# Step 2: Set force_new_cluster on the clean node
ssh -i $SSH_KEY core@<clean-node-ip> \
  sudo crm_attribute --lifetime reboot \
    --node <clean-node-hostname> \
    --name force_new_cluster \
    --update <clean-node-hostname>

# Step 3: Trigger Pacemaker etcd restart
ssh -i $SSH_KEY core@<clean-node-ip> sudo pcs resource cleanup etcd-clone

# Step 4: Monitor (etcd takes ~3 min; kube-apiserver reconnects ~2 min after)
watch "ssh -i $SSH_KEY core@<clean-node-ip> sudo pcs status | grep etcd"
```

See [011](../../adrs/011-odf-tnf-demo5-fencing-procedure.md) for full details and root cause.

### OSD pod down after node recovery

```bash
# Restart OSD pods
oc delete pods -n openshift-storage -l app=rook-ceph-osd
```

---

## Limitations (Developer Preview)

| Feature | Available? |
|---|---|
| ReadWriteOnce (RWO) block PVCs | Yes |
| ReadWriteMany (RWX) shared PVCs | Limited (CephFS only) |
| NooBaa object storage | No |
| NFS file storage | No |
| RADOS Gateway (S3) | No |
| Regional Disaster Recovery | No |
| Metro DR | No |
| Standard Red Hat production support | No |
| Automatic capacity scaling | No |
| Host networking | No |

---

## Why This Matters

This demo addresses the **fundamental storage HA gap** in two-node OpenShift:

- **Demo 2 (LVM/TopoLVM)**: Fast, simple local storage — but a PVC is permanently bound to one node. If that node is fenced, the PVC is unavailable until the node recovers.
- **Demo 5 (ODF + DRBD)**: The floating Ceph monitor via DRBD enables the storage cluster to survive a node failure. The OSD on the surviving node remains healthy, PVCs can be re-attached after applying the `out-of-service` taint, and data is intact.

When this feature reaches GA, it will significantly expand the production use cases for two-node OpenShift at the edge — enabling **stateful, HA workloads on just two nodes** without a third node, third rack, or external storage array.

---

## References

- [ODF 4.21 Two-Node Fencing Developer Preview — Red Hat Customer Portal](https://access.redhat.com/articles/7139231) *(Red Hat account required for install scripts)*
- [ODF 4.21 Release Notes — Two Nodes Fencing (TNF) Support](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.21/html/4.21_release_notes/developer_previews)
- [KMM (Kernel Module Management) Operator](https://docs.openshift.com/container-platform/latest/hardware_enablement/kmm-kernel-module-management.html)
- [DRBD User Guide](https://linbit.com/drbd-user-guide/)
