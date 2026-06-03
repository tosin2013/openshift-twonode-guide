# Demo 5: DRBD Edge Storage — Developer Preview

**Objective**: Demonstrate highly available block storage for the two-node cluster using ODF with DRBD, without the overhead of full Ceph.

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
> The following ODF features are **NOT available** in this configuration:
> - **NooBaa** (object storage / S3-compatible API)
> - **NFS server** export via ODF
> - **RGW (RADOS Gateway / S3)**
> - **Regional Disaster Recovery (Regional DR)**
> - **Metro DR** (synchronous replication across sites)
> - Multi-cluster storage federation
>
> This demo is provided for evaluation and proof-of-concept purposes only.
> For production storage on two-node clusters, use the LVM Operator (see [Demo 2](../02-database-ha/README.md)).

---

## What DRBD Provides

DRBD (Distributed Replicated Block Device) is a kernel-level block device replication mechanism. In the context of TNF:

```
Node 1                              Node 2
┌──────────────────────┐           ┌──────────────────────┐
│  DRBD device: /drbd0 │◄─────────►│  DRBD device: /drbd0 │
│  (UpToDate primary)  │  kernel   │  (UpToDate secondary) │
│                      │  level    │                        │
│  PVC → OSD pod       │  sync     │  PVC → OSD pod         │
└──────────────────────┘           └──────────────────────┘
           ▲
           │  ODF provides PVC/PV abstraction
           ▼
     Application Pod
```

Unlike local storage (LVM), a DRBD-backed PVC can be accessed from either node after a failover, enabling true storage HA without a third node for Ceph quorum.

---

## Prerequisites

- A healthy two-node TNF cluster with OCP 4.22
- ODF 4.21+ operator available in OperatorHub
- Two additional data disks on each node (separate from the OS disk and etcd disk)
- Root/sudo access to the nodes for DRBD kernel module installation
- `oc` CLI and SSH access to both nodes

```bash
# Verify available disks on each node (should see /dev/sdb or /dev/sdc free)
ssh core@192.168.150.21 lsblk
ssh core@192.168.150.22 lsblk

# Verify nodes are clean (no existing ODF/Ceph)
oc get pods -n openshift-storage 2>/dev/null || echo "No storage namespace — OK"
```

---

## Step 1: Install the DRBD Kernel Module

DRBD requires a kernel module. On RHEL CoreOS (the OpenShift node OS), modules must be loaded via a MachineConfig or installed from a compatible RPM.

```bash
# Check if DRBD module is available
ssh core@192.168.150.21 modinfo drbd 2>/dev/null || echo "DRBD module not available — need to install"

# Install DRBD via MachineConfig (requires kmod-drbd from ELRepo or RHEL supplementary)
# Follow the Red Hat documentation for loading third-party kernel modules on RHCOS:
# https://docs.openshift.com/container-platform/4.22/nodes/nodes/nodes-nodes-managing.html

oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-drbd-module
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: drbd-module-load.service
          enabled: true
          contents: |
            [Unit]
            Description=Load DRBD kernel module
            Before=kubelet.service

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/sbin/modprobe drbd

            [Install]
            WantedBy=multi-user.target
EOF

# Wait for nodes to apply the MachineConfig (they will reboot)
oc get mcp master -w
# Wait until UPDATED=True and DEGRADED=False

# Verify module is loaded
ssh core@192.168.150.21 lsmod | grep drbd
```

## Step 2: Install the ODF Operator

```bash
# Install ODF operator via OperatorHub
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: stable-4.14
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for ODF operator to be ready
oc -n openshift-storage wait --for=condition=ready pod -l app=rook-ceph-operator \
  --timeout=300s
```

## Step 3: Label the Storage Nodes

```bash
# Label both nodes as ODF storage nodes
oc label node node1 cluster.ocs.openshift.io/openshift-storage=''
oc label node node2 cluster.ocs.openshift.io/openshift-storage=''

# Verify labels
oc get nodes --show-labels | grep openshift-storage
```

## Step 4: Create the StorageCluster with DRBD

Follow the [Red Hat ODF on Two-Node OpenShift with Fencing Developer Preview guide](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation) to create the StorageCluster CR with DRBD replication. The exact CR format is documented in the Red Hat Developer Preview guide and is subject to change between ODF releases.

The general structure is:

```yaml
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  # Two-node with DRBD configuration
  # Exact parameters — refer to the official Red Hat Developer Preview guide
  storageDeviceSets:
    - name: ocs-deviceset
      count: 1
      replica: 2                   # 2 replicas = both nodes
      dataPVCTemplate:
        spec:
          storageClassName: local-storage  # pre-provisioned local PV
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 100Gi
  # ... additional DRBD-specific parameters as per Red Hat documentation
```

> **Important**: Always follow the current Red Hat ODF Developer Preview documentation for the exact `StorageCluster` specification. The DRBD integration parameters are evolving and the above is a structural reference only.

## Step 5: Verify DRBD Replication is Active

```bash
# SSH to Node 1 and check DRBD status
ssh core@192.168.150.21

# DRBD status (run after StorageCluster is created and OSD pods are running)
sudo drbdadm status

# Expected output (healthy):
# drbd0 role:Primary
#   disk:UpToDate
#   node2 role:Secondary
#     peer-disk:UpToDate
#
# Both "UpToDate" is critical — if node2 shows "Inconsistent" or "DUnknown",
# replication is not healthy.

# Alternative: check via drbdsetup
sudo drbdsetup status --verbose
```

## Step 6: Create a PVC and Write Test Data

```bash
# Create a PVC backed by ODF/DRBD StorageClass
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: drbd-test-pvc
  namespace: openshift-storage
spec:
  storageClassName: ocs-storagecluster-ceph-rbd  # adjust to actual StorageClass name
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF

# Wait for PVC to bind
oc -n openshift-storage get pvc drbd-test-pvc -w
# Wait until STATUS=Bound

# Write test data via a temporary pod
oc apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: drbd-writer
  namespace: openshift-storage
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command:
        - sh
        - -c
        - |
          echo "DRBD test data - $(date)" > /mnt/test/testfile.txt
          echo "Checksum: $(sha256sum /mnt/test/testfile.txt)"
          cat /mnt/test/testfile.txt
          echo "Write complete."
      volumeMounts:
        - name: data
          mountPath: /mnt/test
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: drbd-test-pvc
EOF

oc -n openshift-storage wait --for=condition=complete pod/drbd-writer --timeout=60s
oc -n openshift-storage logs drbd-writer
```

## Step 7: Fence a Node and Verify Data Accessibility

```bash
# Note which node the PVC is currently accessible from
PVC_NODE=$(oc -n openshift-storage get pvc drbd-test-pvc \
  -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}')
echo "PVC is on: ${PVC_NODE}"

# Fence that node
VM_UUID=$(virsh domuuid ${PVC_NODE})
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o off

# Wait for node to be fenced and other node to take over storage
sleep 30
ssh core@192.168.150.21 sudo drbdadm status
# Node 2 should now show: role:Primary, disk:UpToDate

# Read the test data from the surviving node
oc apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: drbd-reader
  namespace: openshift-storage
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command:
        - sh
        - -c
        - |
          echo "Reading test data:"
          cat /mnt/test/testfile.txt
          echo "Checksum verification: $(sha256sum /mnt/test/testfile.txt)"
      volumeMounts:
        - name: data
          mountPath: /mnt/test
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: drbd-test-pvc
EOF

oc -n openshift-storage wait --for=condition=complete pod/drbd-reader --timeout=60s
oc -n openshift-storage logs drbd-reader
# Verify the checksum matches the one from the writer pod
```

## Step 8: Restore and Verify Re-sync

```bash
# Power on the fenced node
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o on

# Wait for the node to rejoin and DRBD to re-sync
oc get nodes -w

# Verify DRBD is back to UpToDate on both nodes
ssh core@192.168.150.21 sudo drbdadm status
# Both nodes should show disk:UpToDate
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| `drbdadm status` (healthy) | Both nodes show `disk:UpToDate` |
| PVC after node failure | Accessible from the surviving node |
| Test file content after failover | Identical to pre-failover write |
| Checksum verification | Matches — data integrity confirmed |
| DRBD re-sync after node recovery | Both nodes return to `UpToDate` |

---

## Limitations (Developer Preview)

| Feature | Available? |
|---|---|
| ReadWriteOnce block PVCs | Yes |
| ReadWriteMany (shared) PVCs | No |
| NooBaa object storage | No |
| NFS file storage | No |
| RADOS Gateway (S3) | No |
| Regional Disaster Recovery | No |
| Metro DR | No |
| Standard Red Hat production support | No |

---

## Cleanup

```bash
oc delete pod drbd-writer drbd-reader -n openshift-storage --ignore-not-found
oc delete pvc drbd-test-pvc -n openshift-storage
# To fully remove ODF: follow the ODF uninstallation guide
```

---

## Why This Matters

This demo directly addresses the storage gap in the two-node architecture. LVM/TopoLVM (Demo 2) provides local storage that is fast and simple, but a PVC is pinned to a single node. DRBD demonstrates a path toward **resilient storage without requiring three nodes for Ceph quorum** — the critical missing piece for full stateful workload HA on TNF. When this feature reaches GA, it will significantly expand the production use cases for two-node OpenShift at the edge.
