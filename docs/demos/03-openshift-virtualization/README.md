# Demo 3: OpenShift Virtualization — Legacy VM HA

**Objective**: Demonstrate running a legacy VM alongside containers on the two-node cluster, and show that the VM recovers automatically after a node failure via OpenShift Virtualization's `RunStrategy: Always`.

---

## Prerequisites

- A healthy two-node TNF cluster (Demo 1 recommended first)
- `oc` CLI with cluster-admin kubeconfig
- `virtctl` CLI (installed in Step 0 below)
- Nested virtualization enabled on both KVM hosts

```bash
# Verify nested virtualization is enabled on both nodes
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

for NODE_IP in 192.168.49.21 192.168.49.22; do
  echo "--- $NODE_IP ---"
  ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@$NODE_IP \
    "cat /sys/module/kvm_intel/parameters/nested || cat /sys/module/kvm_amd/parameters/nested"
done
# Expected: Y or 1 on both nodes
```

---

## Step 0: Install virtctl

`virtctl` is the KubeVirt CLI for managing VMs. Download it from the cluster's built-in download route (handles self-signed certificates):

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

VIRTCTL_URL=$(oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
  -o jsonpath='{.spec.links[?(@.text=="Download virtctl for Linux for x86_64")].href}' 2>/dev/null)

curl -kL "${VIRTCTL_URL}" -o /tmp/virtctl.tar.gz
tar -xzf /tmp/virtctl.tar.gz -C /tmp
sudo mv /tmp/virtctl /usr/local/bin/virtctl
sudo chmod +x /usr/local/bin/virtctl
virtctl version
```

---

## Step 1: Install OpenShift Virtualization (if not already installed)

```bash
# Create the namespace, OperatorGroup, and Subscription
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
  channel: "stable"
EOF

# Install the HyperConverged CR to complete the installation
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF

# Wait for all virt components to be ready (5–10 minutes)
oc -n openshift-cnv rollout status deployment/virt-operator --timeout=600s
oc -n openshift-cnv wait --for=condition=ready pod -l app=virt-controller --timeout=300s
oc -n openshift-cnv wait --for=condition=ready pod -l app=virt-api --timeout=300s
echo "OpenShift Virtualization installed"
```

> **Tip**: Do not specify `startingCSV` in the Subscription — OLM will automatically select the latest stable channel version.

---

## Step 2: Create Local Storage for the VM Disk

OpenShift Virtualization can use any StorageClass. This demo uses a manual `local` PV pinned to `openshift-node1`. Two PVs are required: one for the VM disk and one for CDI's import scratch space.

> **Note on `volumeBindingMode`**: CDI (the image importer) requires `Immediate` binding mode. Using `WaitForFirstConsumer` causes a scheduling deadlock where CDI cannot place the importer pod.

```bash
# Create the StorageClass (Immediate binding mode for CDI compatibility)
oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
reclaimPolicy: Retain
EOF

# Create PV for VM disk on node1
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vm-disk-local-pv
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/lib/kubelet/vm-disk
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - openshift-node1
EOF

# Create PV for CDI scratch space on node1
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vm-scratch-local-pv
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/lib/kubelet/vm-scratch
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - openshift-node1
EOF

# Create the directories on node1
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 \
  "sudo mkdir -p /var/lib/kubelet/vm-disk /var/lib/kubelet/vm-scratch && sudo chmod 777 /var/lib/kubelet/vm-disk /var/lib/kubelet/vm-scratch"

# Verify both PVs are Available
oc get pv vm-disk-local-pv vm-scratch-local-pv
# Expected: STATUS=Available for both
```

---

## Step 3: Create the Demo Namespace and Import the VM Image

This demo uses **CirrOS** — a minimal cloud image (~20 MB) — for a fast import and quick boot. For a production demo, substitute any QCOW2 image URL.

```bash
oc new-project virtualization-demo

# Label namespace for pod security (CDI importer needs baseline)
oc label namespace virtualization-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline

# Import the CirrOS QCOW2 via DataVolume
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: cirros-vm-disk
  namespace: virtualization-demo
spec:
  source:
    http:
      url: "https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
    storageClassName: local-storage
EOF

# Watch import progress (takes 1–3 minutes)
oc -n virtualization-demo get datavolume cirros-vm-disk -w
# Wait until PHASE shows: Succeeded
```

> **CDI scratch space**: CDI requires a temporary scratch PVC during import. The `vm-scratch-local-pv` created in Step 2 satisfies this need.

---

## Step 4: Create the VirtualMachine

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
  # RunStrategy: Always — KubeVirt restarts this VM whenever it stops
  # (including after fencing). This is the key setting for VM HA.
  runStrategy: Always
  template:
    metadata:
      labels:
        app: legacy-inventory
    spec:
      # evictionStrategy: None is required when using local (RWO) storage.
      # The HyperConverged default is LiveMigrate, which stalls on RWO PVCs
      # (cannot live-migrate a disk that is not shared). Setting None allows
      # KubeVirt to simply restart the VM instead of attempting migration.
      evictionStrategy: None
      domain:
        cpu:
          cores: 1
        memory:
          guest: 512Mi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
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
            name: cirros-vm-disk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: cirros
              chpasswd:
                expire: false
EOF

# Wait for the VM to start
oc -n virtualization-demo get vmi -w
# Expected: PHASE=Running within ~30 seconds
```

---

## Step 5: Verify the VM is Running

```bash
# Check VM and VMI status
oc -n virtualization-demo get vm,vmi
# Expected: VM STATUS=Running, VMI PHASE=Running

# Note the node the VM is running on
VM_NODE=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.status.nodeName}')
echo "VM is running on: ${VM_NODE}"

# Record the VMI UID (new UID after fencing confirms VM restarted)
PRE_FENCE_UID=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.metadata.uid}')
echo "VMI UID before fencing: ${PRE_FENCE_UID}"

# Connect to the VM console to verify it boots (exit with Ctrl+])
virtctl console -n virtualization-demo legacy-inventory
```

Expected console output inside CirrOS:
```
login as 'cirros' user. default password: 'gocubsgo'
```
*(CirrOS uses `gocubsgo` as the default password)*

---

## Step 6: Pre-Fencing Health Checks

Before fencing, verify the cluster is healthy:

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Verify Pacemaker is clean
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 sudo pcs resource cleanup
sleep 5
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 sudo pcs status
# Expected: Online: [ openshift-node1 openshift-node2 ]
# No Failed Resource Actions

# Verify both etcd members are healthy
oc exec -n openshift-etcd etcd-openshift-node1 -c etcdctl -- \
  sh -c 'unset ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY; \
  etcdctl \
  --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
  --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.crt \
  --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.key \
  --endpoints=https://localhost:2379 member list -w table'
# Expected: 2 members, both "started"
```

---

## Step 7: Fence the Node Running the VM

```bash
# Use the node running the VM (from Step 5)
echo "Fencing node: ${VM_NODE}"

# Get the sushy-tools UUID for this VM
VM_UUID=$(sudo virsh domuuid ${VM_NODE})
echo "VM UUID: ${VM_UUID}"

# Fence via Redfish BMC (sushy-tools on host)
sudo fence_redfish \
  -a 192.168.122.10 \
  --ssl-insecure \
  -l admin \
  -p admin \
  --systems-uri "/redfish/v1/Systems/${VM_UUID}" \
  --ipport 8000 \
  -o off

# Verify the node KVM domain is off
sudo virsh domstate ${VM_NODE}
# Expected: shut off

# Verify the node is NotReady in Kubernetes
oc get node ${VM_NODE}
# Expected: STATUS=NotReady (within ~40 seconds)
```

---

## Step 8: Monitor the VM Recovery

> **Important**: With local RWO storage, the VM cannot restart on the **surviving** node (the disk physically lives on the fenced node). The VM enters `Scheduling` state and waits. It will restart on the **original node** once that node recovers.

> This is the fundamental trade-off of local storage. For cross-node VM failover with persistent disk data, shared RWX storage (Ceph, NFS) is required.

```bash
# Watch the VMI status transition
for i in $(seq 1 12); do
  PHASE=$(oc -n virtualization-demo get vmi legacy-inventory \
    -o jsonpath='{.status.phase}' 2>/dev/null)
  NODE=$(oc -n virtualization-demo get vmi legacy-inventory \
    -o jsonpath='{.status.nodeName}' 2>/dev/null)
  CURR_UID=$(oc -n virtualization-demo get vmi legacy-inventory \
    -o jsonpath='{.metadata.uid}' 2>/dev/null)
  POD=$(oc -n virtualization-demo get pods --no-headers 2>/dev/null | grep virt-launcher | awk '{print $1,"→",$3}')
  echo "$(date +%H:%M:%S) — VMI: ${PHASE}/${NODE:-pending} | NewUID: $([ "$CURR_UID" != "$PRE_FENCE_UID" ] && echo YES || echo no) | Pod: ${POD}"
  sleep 20
done
```

Expected sequence after fencing:
```
# Phase 1 (0–5 min): Stale entry — node not yet NotReady
19:07:30 — VMI: Running/openshift-node1 | NewUID: no | Pod: virt-launcher-legacy-inventory-xxxxx → Running

# Phase 2 (5 min): KubeVirt detects node failure, deletes old VMI, creates new VMI
19:07:54 — VMI: Scheduling/ | NewUID: YES | Pod: virt-launcher-legacy-inventory-yyyyy → Pending

# Phase 3 (5+ min): New pod Pending — disk on fenced node, cannot schedule elsewhere
19:08:10 — VMI: Scheduling/ | NewUID: YES | Pod: virt-launcher-legacy-inventory-yyyyy → Pending
```

---

## Step 9: Restore the Fenced Node

The VM will restart automatically when the node comes back online:

```bash
# Power on the fenced node
sudo virsh start ${VM_NODE}

# Watch for node to return Ready
for i in $(seq 1 12); do
  STATUS=$(oc get node ${VM_NODE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  echo "$(date +%H:%M:%S) — ${VM_NODE} Ready: $STATUS"
  [[ "$STATUS" == "True" ]] && echo "✅ Node is back!" && break
  sleep 20
done
```

---

## Step 10: Validate Post-Recovery State

```bash
# Watch for VM to come back Running
for i in $(seq 1 8); do
  PHASE=$(oc -n virtualization-demo get vmi legacy-inventory \
    -o jsonpath='{.status.phase}' 2>/dev/null)
  NODE=$(oc -n virtualization-demo get vmi legacy-inventory \
    -o jsonpath='{.status.nodeName}' 2>/dev/null)
  echo "$(date +%H:%M:%S) — VMI: ${PHASE}/${NODE:-pending}"
  [[ "$PHASE" == "Running" && -n "$NODE" ]] && echo "✅ VM is Running on ${NODE}!" && break
  sleep 15
done

# Verify it is a new VMI (new UID = VM restarted clean from disk)
POST_FENCE_UID=$(oc -n virtualization-demo get vmi legacy-inventory \
  -o jsonpath='{.metadata.uid}')
echo ""
echo "VMI UID before fencing: ${PRE_FENCE_UID}"
echo "VMI UID after fencing:  ${POST_FENCE_UID}"
[[ "$PRE_FENCE_UID" != "$POST_FENCE_UID" ]] && echo "✅ New VMI — VM restarted" || echo "⚠️  Same UID — check VM state"

# Verify console access
virtctl console -n virtualization-demo legacy-inventory
```

---

## Step 11: Post-Recovery Cleanup

```bash
# Clean up Pacemaker resource state
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 sudo pcs resource cleanup
sleep 5
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 sudo pcs status
# Expected: No Failed Resource Actions

# If etcd-clone shows Stopped on recovered node:
ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@192.168.49.21 \
  sudo pcs resource restart etcd-clone

# Wait for cluster operators to converge (~5 minutes)
oc get co | grep -v "True.*False.*False"
# Expected: no output (all COs Available=True, Progressing=False, Degraded=False)
```

---

## Expected Validation Summary

| Check | Expected Result |
|---|---|
| VMI phase after fencing | `Scheduling` (new UID) — RunStrategy fired |
| Pod after fencing (local storage) | `Pending` — disk on fenced node, cannot schedule to survivor |
| VMI after node recovery | `Running` on the recovered original node |
| VMI UID change | New UID confirms VM was restarted (not resumed from saved state) |
| VM console access after recovery | VM boots fresh from disk image |
| All cluster operators after recovery | `Available=True, Degraded=False` within 5–7 min |

---

## Known Issues and Workarounds

### 1. VM Won't Start After Fencing — `evictionStrategy` Conflict

**Symptom**: After fencing, the VMI stays `Running` on the dead node for 5+ minutes (stale entry). After the stale entry is cleared, the new VMI stays in `Scheduling` indefinitely with event:
```
EvictionStrategy is set but vmi is not migratable: PVC is not shared, live migration requires ReadWriteMany access mode
```

**Root cause**: The `HyperConverged` CR sets `evictionStrategy: LiveMigrate` as the global default. KubeVirt tries to live-migrate instead of restarting, but the RWO local PVC cannot be migrated. The controller stalls.

**Fix**: Set `evictionStrategy: None` on the VM spec (as shown in Step 4). This overrides the HyperConverged default for this VM and allows restart-based HA.

```bash
# Patch an existing VM to fix this
oc -n virtualization-demo patch vm legacy-inventory --type=merge \
  -p '{"spec":{"template":{"spec":{"evictionStrategy":"None"}}}}'
```

### 2. KubeVirt Webhook Unavailable After Fencing

**Symptom**: `oc` commands targeting `virtualmachines.kubevirt.io` fail with:
```
failed calling webhook "virtualmachines-mutator.kubevirt.io": no endpoints available for service "virt-api"
```

**Root cause**: The `virt-api` Deployment pods were scheduled on the now-fenced node. The webhook endpoint is gone.

**Fix**: Force-delete all `openshift-cnv` pods stuck on the dead node. Kubernetes will reschedule them on the surviving node within ~1–2 minutes.

```bash
DEAD_NODE="openshift-node1"   # adjust to whichever node was fenced

for POD in $(oc -n openshift-cnv get pods -o wide --no-headers | \
    grep "${DEAD_NODE}" | awk '{print $1}'); do
  echo "Force deleting: $POD"
  oc -n openshift-cnv delete pod $POD --force --grace-period=0
done

# Wait for virt-api to come up on surviving node
oc -n openshift-cnv wait --for=condition=ready pod -l app=virt-api --timeout=120s
```

### 3. VM Cannot Restart on Surviving Node — Local Storage is Node-Bound

**Symptom**: After fencing, the new VMI pod is stuck `Pending`:
```
0/2 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity,
1 node(s) had untolerated taint(s)
```

**Root cause**: The `local` PV has `nodeAffinity` pinned to the fenced node. The disk physically lives on that node — it cannot be accessed from another node.

**Behavior**: The VM stays in `Scheduling` until the original node recovers, then restarts there.

**For cross-node VM failover** with persistent disk data, shared RWX storage (Ceph, NFS, DRBD) is required. See [Demo 5: DRBD Edge Storage](../05-drbd-edge-storage/README.md).

---

## Notes on VM HA Behavior

- **`RunStrategy: Always`** fires immediately when the virt-launcher pod is deleted. The new VMI creation is prompt; the delay is purely the 5-minute Kubernetes node eviction timeout before the old stale pod is cleared.
- **VM state** (RAM contents) is **not** preserved across a fencing event. The VM performs a clean reboot from disk. Applications that persist state to disk recover; in-memory-only state is lost.
- **Live migration** requires `ReadWriteMany` (RWX) shared storage. TNF with local storage uses `ReadWriteOnce` — live migration is unavailable by design.
- **virt-api availability**: In a 2-node cluster, the `virt-api` Deployment may land both pods on the same node. After fencing that node, the webhook becomes unavailable. Force-deleting pods on the dead node restores it within ~2 minutes (pods reschedule to surviving node).

---

## Validated Results (2026-06-04)

**Cluster**: TNF on KVM (IBM Cloud bare metal), OCP 4.22.0-rc.5, CNV v4.21.8

**Scenario**: CirrOS VM (`legacy-inventory`) running on `openshift-node1`. `openshift-node1` fenced via `fence_redfish`. Node restored after ~2 minutes.

**Observations**:
- KubeVirt `RunStrategy: Always` correctly fired and created a new VMI (new UID) within 5 minutes of fencing
- Initial issue: `HyperConverged` global `evictionStrategy: LiveMigrate` blocked the VMI restart — KubeVirt tried to live-migrate but the PVC is RWO. Fix: added `evictionStrategy: None` to the VM spec
- After fencing, `virt-api` pods on the dead node made the KubeVirt webhook unavailable. Fix: force-delete all dead-node pods in `openshift-cnv` namespace
- With local RWO storage, the new VMI pod was `Pending` until `openshift-node1` recovered (~2 min)
- Upon node recovery: pod scheduled, VM booted, VMI reached `Running` in ~65 seconds
- New VMI UID confirmed: VM restarted clean from disk (not resumed)
- Pacemaker cluster healthy after `pcs resource cleanup`
- All cluster operators recovered within 5 minutes

**Recovery timeline**:
- T+0: `fence_redfish -o off` issued, KVM domain goes `shut off`
- T+40s: `openshift-node1` goes `NotReady`
- T+5m: Kubernetes eviction fires, stale VMI deleted, new VMI (`Scheduling`) created
- T+5m+15s: `virsh start openshift-node1` issued
- T+7m: `openshift-node1` returns `Ready`
- T+7m+65s: VM `Running` on `openshift-node1` with new UID

---

## Cleanup

```bash
oc delete project virtualization-demo
oc delete pv vm-disk-local-pv vm-scratch-local-pv
```

---

## Why This Matters

Many retail and manufacturing edge sites run legacy applications in VMs. This demo proves that the two-node cluster can unify VM and container workloads on minimal hardware — a key differentiator over traditional hypervisors that cannot co-locate VMs and cloud-native containers on the same platform.

For environments requiring live migration (zero-downtime VM HA), the same platform supports DRBD or Ceph-backed shared storage as a future enhancement.
