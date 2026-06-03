# Demo 3: OpenShift Virtualization — Legacy VM HA

**Objective**: Demonstrate running a legacy VM alongside containers on the two-node cluster, and show that the VM recovers after a node failure via OpenShift Virtualization's fencing-aware VM HA.

---

## Prerequisites

- A healthy two-node TNF cluster (Demo 1 recommended first)
- OpenShift Virtualization (KubeVirt) operator installed
- A RHEL or CentOS/Rocky Linux QCOW2 image accessible from the cluster
- `oc` and `virtctl` CLIs configured
- LVM Operator storage class available (from Demo 2 setup)

```bash
# Verify OpenShift Virtualization is installed
oc get csv -n openshift-cnv | grep kubevirt
# Expected: kubevirt-hyperconverged <version> Succeeded

# Install virtctl if not present
VERSION=$(oc get csv -n openshift-cnv -o jsonpath='{.items[0].spec.version}' 2>/dev/null)
curl -LO https://github.com/kubevirt/kubevirt/releases/download/v${VERSION}/virtctl-v${VERSION}-linux-amd64
sudo mv virtctl-v${VERSION}-linux-amd64 /usr/local/bin/virtctl
sudo chmod +x /usr/local/bin/virtctl
```

### Installing OpenShift Virtualization (if not already installed)

```bash
# Create the openshift-cnv namespace and install via OperatorHub
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  startingCSV: kubevirt-hyperconverged-operator.v4.14.0
  channel: "stable"
EOF

# Install HyperConverged CR to complete the installation
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF

# Wait for all components to be ready (takes 5-10 minutes)
oc -n openshift-cnv wait --for=condition=ready pod -l app=virt-operator --timeout=300s
```

---

## Scenario

A RHEL or Rocky Linux VM is imported from a QCOW2 image using the Containerized Data Importer (CDI). The VM represents a legacy inventory management system. Node 2 is then fenced, and the VM is observed to restart on Node 1 automatically via `RunStrategy: Always`.

---

## Step 1: Create the Demo Namespace and Import the VM Image

```bash
oc new-project virtualization-demo

# Option A: Import from a URL (requires internet access from the cluster)
# Using CentOS Stream 9 as a publicly available QCOW2
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: legacy-inventory-vm-disk
  namespace: virtualization-demo
spec:
  source:
    http:
      url: "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
    storageClassName: lvms-vg1   # adjust to your StorageClass name
EOF

# Option B: Import from a local file (requires HTTP server on bastion)
# Serve the QCOW2 file: python3 -m http.server 8080 --directory /path/to/images
# Then use url: http://<bastion-ip>:8080/rhel9.qcow2

# Watch the import progress
oc -n virtualization-demo get datavolume legacy-inventory-vm-disk -w
# Wait until PHASE shows: Succeeded
```

## Step 2: Create the VirtualMachine

```bash
oc apply -f - <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: legacy-inventory
  namespace: virtualization-demo
  labels:
    app: legacy-inventory
spec:
  # RunStrategy: Always — the VM will automatically restart after any failure,
  # including after fencing. This is the key setting for VM HA.
  runStrategy: Always
  template:
    metadata:
      labels:
        app: legacy-inventory
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 2Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: legacy-inventory-vm-disk
      # Cloud-init to set a root password and hostname
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            hostname: legacy-inventory
            chpasswd:
              list: |
                root:redhat123
              expire: false
            ssh_pwauth: true
EOF

# Wait for the VM to start
oc -n virtualization-demo get vmi -w
# Wait until PHASE shows: Running
```

## Step 3: Verify the VM is Running and Accessible

```bash
# Check VM instance status
oc -n virtualization-demo get vmi legacy-inventory -o wide
# Note which node it is running on

# Connect to the VM console (exit with Ctrl+])
virtctl console -n virtualization-demo legacy-inventory

# Or connect via SSH if the VM has a routable IP
# virtctl ssh root@legacy-inventory -n virtualization-demo

# Inside the VM — verify it is functional
hostname
uptime
```

## Step 4: Record Pre-Fencing State

```bash
# Note the node the VM is running on
VM_NODE=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.status.nodeName}')
echo "VM is running on: ${VM_NODE}"

# Note the VMI UID to confirm a new VMI is created after fencing (different UID = VM restarted)
VM_UID=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.metadata.uid}')
echo "VMI UID before fencing: ${VM_UID}"
```

## Step 5: Fence the Node Running the VM

```bash
# Fence the node hosting the VM
echo "Fencing node: ${VM_NODE}"

# For KVM:
VM_UUID=$(virsh domuuid ${VM_NODE})
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o off

# For bare metal:
# fence_redfish -a <bmc-ip> -l <user> -p <pass> -b "/redfish/v1/Systems/<id>" -o off
```

## Step 6: Observe VM Recovery

After fencing, watch the VM recovery sequence:

```bash
# Watch the VMI status transition
oc -n virtualization-demo get vmi -w
# Expected sequence:
#   Running  →  Failed  (node unreachable)
#   Failed   →  Scheduling  (RunStrategy: Always triggers restart)
#   Scheduling  →  Running  (on the surviving node)

# Watch VirtualMachine events
oc -n virtualization-demo describe vm legacy-inventory | tail -30
# Look for: VirtualMachineInstanceRestarted event
```

## Step 7: Validate Post-Recovery State

```bash
# Verify the VM is running on the surviving node
oc -n virtualization-demo get vmi legacy-inventory -o wide
# NODE column should show the surviving node (different from before fencing)

# Verify a NEW VMI was created (different UID = successful restart)
NEW_VM_UID=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.metadata.uid}')
echo "VMI UID before fencing: ${VM_UID}"
echo "VMI UID after fencing:  ${NEW_VM_UID}"
# UIDs should differ if the VM restarted

# Connect to the recovered VM
virtctl console -n virtualization-demo legacy-inventory
# Verify hostname and uptime are as expected
hostname
uptime
```

## Step 8: Restore the Fenced Node

```bash
# Power on the fenced node
# For KVM:
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o on

# Wait for the node to rejoin
oc get nodes -w
# Both nodes should return to Ready
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| VM status during node failure | `vmi` transitions: Running → Failed → Scheduling → Running |
| VM node after recovery | Running on the surviving node (different from pre-fencing) |
| VMI UID change | New UID confirms VM was restarted (not resumed) |
| VM console access after recovery | VM responsive, hostname matches, uptime reset |
| All cluster operators after recovery | `Available=True, Progressing=False, Degraded=False` |

---

## Notes on VM HA Behavior

- **`RunStrategy: Always`** is the key configuration. It tells KubeVirt to restart the VM whenever it stops for any reason, including node failure after fencing.
- VM **state** (RAM contents) is **not** preserved across a fencing event. The VM restarts from the disk image. This is equivalent to a hard reboot — applications that persist state to disk will recover; in-memory-only state is lost.
- **Live migration** (graceful VM movement without restart) requires shared storage between nodes. On TNF with local storage, live migration is not available. Only restart-based HA (`RunStrategy: Always`) is supported.
- For shared storage enabling live migration, see [Demo 5: DRBD Edge Storage](../05-drbd-edge-storage/README.md) (Developer Preview).

---

## Cleanup

```bash
oc delete project virtualization-demo
```

---

## Why This Matters

Many retail and manufacturing edge sites run legacy applications in VMs. This demo proves that the two-node cluster can unify VM and container workloads on minimal hardware — a key differentiator over traditional hypervisors that cannot co-locate VMs and cloud-native containers on the same platform.
