# Demo 6: VM Live Migration — OpenShift Virtualization + ODF CephFS

**Objective**: Demonstrate zero-downtime VM live migration between the two cluster
nodes using OpenShift Virtualization backed by ODF CephFS shared storage. Show both
operator-initiated migration (`virtctl migrate`) and maintenance-driven migration
(`oc adm drain`).

> ⚠ **Experimental — Two-Node Topology Notice**
>
> Red Hat's official documentation recommends a minimum of three worker nodes for
> production live migration workloads. This demo runs on a two-node TNF cluster
> (two schedulable control-plane nodes, zero dedicated workers), which is outside
> the recommended node count. Live migration is **technically functional** on this
> topology because:
> - The cluster `infrastructureTopology` is `HighlyAvailable` (not `SingleReplica`)
> - ODF CephFS provides `ReadWriteMany` (RWX) access — the hard storage requirement
> - There are two schedulable nodes for the migration handoff
>
> Use this demo to understand live migration mechanics on edge hardware. For
> production, size to three or more worker nodes.

---

## How Live Migration Works on TNF

```
Before migration:
  node1: virt-launcher-pod (VM running) ← active
  node2: (no VM)

During migration:
  node1: virt-launcher-pod (source)     ← still serving traffic
  node2: virt-launcher-pod (target)     ← warming up, syncing memory

After migration:
  node1: (no VM)
  node2: virt-launcher-pod (VM running) ← now active, zero downtime
```

KubeVirt copies the VM's memory pages from source to target in the background.
When the dirty-page rate drops below the migration bandwidth threshold, it performs
a final synchronization and switches the network to the target node.
The VM is never paused for more than a few milliseconds.

---

## Prerequisites

| Requirement | How to Verify |
|---|---|
| Demo 5 (ODF + DRBD) deployed and `HEALTH_OK` | `oc exec -n openshift-storage rook-ceph-tools-* -- ceph status` |
| `ocs-storagecluster-cephfs` StorageClass present | `oc get sc ocs-storagecluster-cephfs` |
| OpenShift Virtualization installed (`kubevirt-hyperconverged`) | `oc get hco -n openshift-cnv` |
| `virtctl` CLI on bastion | `virtctl version` |
| Nested virtualization on both nodes | `cat /sys/module/kvm_intel/parameters/nested` (must be `Y`) |

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Quick prerequisite check
echo "=== ODF Health ===" && \
  oc exec -n openshift-storage \
    $(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name | head -1) \
    -- ceph status 2>/dev/null | grep -E "health:|cluster:"

echo "=== CephFS StorageClass ===" && \
  oc get sc ocs-storagecluster-cephfs -o jsonpath='{.metadata.name}: {.provisioner}{"\n"}'

echo "=== HyperConverged ===" && \
  oc get hco kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='HCO: {.status.conditions[?(@.type=="Available")].status}{"\n"}'

echo "=== virtctl ===" && virtctl version --client

echo "=== Nested virt ===" && \
  for NODE_IP in 192.168.49.21 192.168.49.22; do
    echo -n "  $NODE_IP: "
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@$NODE_IP \
      "cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || \
       cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo 'not-found'"
  done
```

Expected output:
```
=== ODF Health ===
    health: HEALTH_OK
=== CephFS StorageClass ===
ocs-storagecluster-cephfs: openshift-storage.cephfs.csi.ceph.com
=== HyperConverged ===
HCO: True
=== virtctl ===
Client Version: version.Info{GitVersion:"v1.x.y"...}
=== Nested virt ===
  192.168.49.21: Y
  192.168.49.22: Y
```

---

## Step 0: Run Pre-Flight Check

```bash
bash scripts/tnf-preflight-validate.sh
# All checks must pass before proceeding
```

---

## Step 1: Verify the Cluster's Infrastructure Topology

Red Hat's live migration engine checks `infrastructureTopology` before allowing
migrations. Confirm it is `HighlyAvailable` (not `SingleReplica`):

```bash
oc get infrastructure cluster \
  -o jsonpath='infrastructureTopology: {.status.infrastructureTopology}{"\n"}'
# Expected: infrastructureTopology: HighlyAvailable
```

---

## Step 2: Create the Demo Namespace and CephFS RWX PVC

```bash
oc new-project live-migration-demo

# Label namespace for pod security (virt-launcher needs baseline)
oc label namespace live-migration-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline

# Create a DataVolume using the CephFS StorageClass (RWX access mode)
# CephFS supports ReadWriteMany — this is what enables live migration
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora-vm-disk
  namespace: live-migration-demo
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  source:
    http:
      url: "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2"
  pvc:
    storageClassName: ocs-storagecluster-cephfs
    accessModes:
      - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: 10Gi
EOF

# Monitor the import progress
oc -n live-migration-demo get datavolume fedora-vm-disk -w
# Wait for PHASE: Succeeded (3–10 minutes depending on download speed)
```

> **Why `Block` volume mode?** Red Hat recommends `Block` + `RWX` for VM disks —
> it avoids the filesystem layer that `Filesystem` mode adds and gives better I/O
> performance. CephFS with `Block` mode uses a raw RBD image through the CephFS
> driver.

> **Slow download?** The Fedora Cloud image is ~400 MB. For a faster demo, use
> CirrOS (~20 MB) instead — replace the URL with
> `https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img`
> and set `storage: 2Gi`. CirrOS has less RAM to migrate but proves the mechanism.

---

## Step 3: Create the VirtualMachine

```bash
oc apply -f - <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-live-migrate
  namespace: live-migration-demo
  labels:
    app: fedora-live-migrate
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: fedora-live-migrate
    spec:
      # LiveMigrateIfPossible: attempt live migration when the node is drained
      # or when virtctl migrate is called. If migration cannot complete (e.g.,
      # bandwidth timeout), fall back to restart rather than blocking indefinitely.
      evictionStrategy: LiveMigrateIfPossible
      domain:
        cpu:
          cores: 1
        memory:
          guest: 1Gi
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
            name: fedora-vm-disk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: fedora
              chpasswd:
                expire: false
              runcmd:
                - while true; do echo "$(date): alive on $(hostname)" >> /tmp/heartbeat.log; sleep 5; done
EOF

# Wait for the VM to reach Running
oc -n live-migration-demo get vmi -w
# Expected: fedora-live-migrate   Running   <node>   <age>
```

---

## Step 4: Verify the VM is Live-Migratable

Before triggering migration, confirm KubeVirt reports the VM as migratable:

```bash
# Check the LiveMigratable condition on the VMI
oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool | \
  grep -A3 "LiveMigratable"
# Expected: "status": "True", "type": "LiveMigratable"

# One-liner version
oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}'
# Expected: True

# Record which node the VM is currently on
PRE_MIGRATE_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
echo "VM is currently on: ${PRE_MIGRATE_NODE}"

# Record the VMI UID — same UID after migration confirms zero restart
PRE_MIGRATE_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')
echo "VMI UID: ${PRE_MIGRATE_UID}"
```

If `LiveMigratable` is `False`, check the reason:

```bash
oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}'
# Common reason: "PVC is not shared" → DataVolume didn't use RWX
# Fix: delete and recreate the DataVolume with accessModes: [ReadWriteMany]
```

---

## Step 5a: Manual Migration — `virtctl migrate`

This is the most direct way to trigger a live migration:

```bash
# Trigger the migration
virtctl migrate -n live-migration-demo fedora-live-migrate
# Output: VM fedora-live-migrate was scheduled to migrate

# Watch the VirtualMachineInstanceMigration resource
oc -n live-migration-demo get vmim -w
# Expected progression:
#   NAME                                PHASE       VMI
#   kubevirt-migrate-xxxxxxxx           Pending     fedora-live-migrate
#   kubevirt-migrate-xxxxxxxx           Scheduling  fedora-live-migrate
#   kubevirt-migrate-xxxxxxxx           Running     fedora-live-migrate
#   kubevirt-migrate-xxxxxxxx           Succeeded   fedora-live-migrate
```

While the migration is running, watch the source and target node in real time:

```bash
# In a second terminal — poll migration state every 2 seconds
watch -n2 "
  echo '=== VMI ===' && \
  oc -n live-migration-demo get vmi fedora-live-migrate \
    -o custom-columns='NODE:.status.nodeName,PHASE:.status.phase,MIGRATION:.status.migrationState.completed' && \
  echo '=== VMIM ===' && \
  oc -n live-migration-demo get vmim \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,SOURCE:.status.migrationState.sourceNode,TARGET:.status.migrationState.targetNode'
"
```

After migration succeeds, verify:

```bash
# Check the VM moved to a different node
POST_MIGRATE_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
echo "VM before migration: ${PRE_MIGRATE_NODE}"
echo "VM after migration:  ${POST_MIGRATE_NODE}"
[[ "$PRE_MIGRATE_NODE" != "$POST_MIGRATE_NODE" ]] && \
  echo "✅ VM migrated to a different node" || \
  echo "⚠️  VM is on the same node — check migration logs"

# Confirm the VMI UID is UNCHANGED — same UID = live migration (no reboot)
POST_MIGRATE_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')
echo ""
echo "VMI UID before: ${PRE_MIGRATE_UID}"
echo "VMI UID after:  ${POST_MIGRATE_UID}"
[[ "$PRE_MIGRATE_UID" == "$POST_MIGRATE_UID" ]] && \
  echo "✅ Same UID — live migration confirmed (VM was never restarted)" || \
  echo "⚠️  Different UID — VM was restarted, not migrated"
```

Inspect the completed migration object for timing details:

```bash
VMIM_NAME=$(oc -n live-migration-demo get vmim \
  -o jsonpath='{.items[0].metadata.name}')

oc -n live-migration-demo get vmim ${VMIM_NAME} \
  -o jsonpath='{
    "Source node:   "}{.status.migrationState.sourceNode}{"\n"}{
    "Target node:   "}{.status.migrationState.targetNode}{"\n"}{
    "Started at:    "}{.status.migrationState.startTimestamp}{"\n"}{
    "Ended at:      "}{.status.migrationState.endTimestamp}{"\n"}{
    "Completed:     "}{.status.migrationState.completed}{"\n"}{
    "Failed:        "}{.status.migrationState.failed}{"\n"}'
```

---

## Step 5b: Maintenance-Driven Migration — `oc adm drain`

This simulates a planned node maintenance window. KubeVirt intercepts the node
drain and triggers live migrations for all eligible VMs before the node is cordoned.

```bash
# Use the node the VM is currently on
DRAIN_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
echo "Draining: ${DRAIN_NODE}"

# Update the pre-drain baseline
PRE_DRAIN_NODE="${DRAIN_NODE}"
PRE_DRAIN_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')

# Cordon the node (mark unschedulable) and drain workloads
# --pod-selector=kubevirt.io: ensures we only discuss VMs here, but drain
# handles all pods; --delete-emptydir-data needed for virt-launcher pods
oc adm drain ${DRAIN_NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=300s
```

While the drain runs, watch the migration in a second terminal:

```bash
oc -n live-migration-demo get vmim -w
# Expected: a new VMIM object created automatically, reaching Succeeded
```

After the drain completes:

```bash
# Confirm the VM is now on the surviving node
POST_DRAIN_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
POST_DRAIN_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')

echo "Node before drain: ${PRE_DRAIN_NODE}"
echo "Node after drain:  ${POST_DRAIN_NODE}"
[[ "$PRE_DRAIN_NODE" != "$POST_DRAIN_NODE" ]] && \
  echo "✅ VM migrated off the drained node" || \
  echo "⚠️  VM is still on the same node"

[[ "$PRE_DRAIN_UID" == "$POST_DRAIN_UID" ]] && \
  echo "✅ Same UID — live migration confirmed" || \
  echo "⚠️  Different UID — VM was restarted (check evictionStrategy)"

# Uncordon the node to restore full cluster capacity
oc adm uncordon ${DRAIN_NODE}
oc get nodes
# Expected: both nodes Ready, SchedulingDisabled removed
```

---

## Step 6: Validate Heartbeat Continuity

The VM runs a heartbeat loop writing timestamps to `/tmp/heartbeat.log` every 5 seconds
(set up in the cloud-init `userData`). If live migration succeeded with zero downtime,
the heartbeat log should have no gaps:

```bash
# Access the VM console
virtctl console -n live-migration-demo fedora-live-migrate
# Login: fedora / fedora

# Inside the VM:
tail -20 /tmp/heartbeat.log
# Expected: continuous 5-second entries with no gaps around the migration time
# Example:
#   Mon Jun  9 12:00:00 UTC 2026: alive on fedora-live-migrate
#   Mon Jun  9 12:00:05 UTC 2026: alive on fedora-live-migrate
#   Mon Jun  9 12:00:10 UTC 2026: alive on fedora-live-migrate  ← migration happened here
#   Mon Jun  9 12:00:15 UTC 2026: alive on fedora-live-migrate  ← no gap = zero downtime

# Count entries to verify no restart happened
wc -l /tmp/heartbeat.log
# A restart would reset the file. A live migration preserves it.
```

Exit the console with `Ctrl+]`.

---

## Step 7: Post-Demo Cluster Health Check

```bash
# Clear Pacemaker state
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Expected: both nodes Online, no Failed Resource Actions

# Verify all cluster operators recovered
oc get co | grep -v "True.*False.*False"
# Expected: no output

# Run pre-flight to confirm baseline is restored
bash scripts/tnf-preflight-validate.sh
```

---

## Expected Validation Summary

| Check | Expected Result |
|---|---|
| `LiveMigratable` condition on VMI | `True` before any migration |
| `virtctl migrate` result | `VirtualMachineInstanceMigration` reaches `Succeeded` |
| VM node after manual migration | Different from pre-migration node |
| VMI UID after manual migration | **Unchanged** — confirms live migration, not restart |
| Heartbeat log continuity | No gaps — VM was never paused or rebooted |
| VM node after `oc adm drain` | Automatically migrated to surviving node |
| Cluster operators after drain+uncordon | All `Available`, no `Degraded` |

---

## Known Issues and Workarounds

### 1. `LiveMigratable: False` — PVC Not RWX

**Symptom**:
```
oc get vmi fedora-live-migrate -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}'
# PVC is not shared, live migration requires that all PVCs must be shared
# (using ReadWriteMany access mode)
```

**Cause**: The DataVolume was created with `accessModes: [ReadWriteOnce]` instead of `ReadWriteMany`, or with `storageClassName: local-storage` from Demo 3.

**Fix**: Delete the DataVolume and VM, then recreate with `accessModes: [ReadWriteMany]` and `storageClassName: ocs-storagecluster-cephfs`.

---

### 2. Migration Stuck in `Running` — Bandwidth or Memory Dirty Rate

**Symptom**: `oc get vmim` shows `Running` for more than 5 minutes.

**Cause**: The VM's memory dirty rate (rate of memory page changes) exceeds the migration bandwidth, so the migration cannot converge. On a KVM dev host with constrained bandwidth this can occur with active workloads.

**Fix**: Either reduce the VM's memory write rate, or tune the migration bandwidth in the `HyperConverged` CR:

```bash
oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge -p '{
  "spec": {
    "liveMigrationConfig": {
      "bandwidthPerMigration": "0",
      "completionTimeoutPerGiB": 800,
      "progressTimeout": 150
    }
  }
}'
# bandwidthPerMigration: "0" = unlimited (uses full network bandwidth)
```

---

### 3. Migration Fails — `virt-launcher` Pod Scheduling Failure on Target Node

**Symptom**: `oc get vmim` shows `Failed`. The `virt-launcher-<name>-migration` pod is `Pending`.

**Cause**: The target node has insufficient CPU or memory to start the migration target pod. On a constrained KVM host, all CPU/memory may be consumed by the existing workload.

**Fix**: Reduce resource requests on the VM or free up capacity on the target node:

```bash
# Check target node capacity
oc describe node <target-node> | grep -A10 "Allocated resources"

# Reduce VM CPU/memory if needed (requires VM restart)
oc -n live-migration-demo patch vm fedora-live-migrate --type=merge -p '{
  "spec": {"template": {"spec": {"domain": {"cpu": {"cores": 1},
    "memory": {"guest": "512Mi"}}}}}}'
```

---

### 4. `oc adm drain` Timeout — Migration Does Not Complete in Time

**Symptom**: `drain` exits with timeout error before migration completes.

**Cause**: The default 300-second `--timeout` is not enough if the Fedora image is large and the memory dirty rate is high.

**Fix**: Increase the timeout or use `virtctl migrate` first to pre-drain the VM before running `oc adm drain`:

```bash
# Pre-migrate the VM manually, then drain with no VMs to migrate
virtctl migrate -n live-migration-demo fedora-live-migrate
# Wait for Succeeded
oc adm drain ${DRAIN_NODE} --ignore-daemonsets --delete-emptydir-data --force --timeout=600s
```

---

## Notes on Live Migration Behavior

- **Memory, not disk** is what migrates. The VM disk stays on the CephFS RWX PVC and is shared between source and target — both nodes mount it simultaneously during migration. Only the in-memory state (RAM pages, CPU registers, device state) is transferred over the network.
- **Network continuity** is maintained by KubeVirt updating the OVNKubernetes port binding from the source `virt-launcher` pod to the target one at the moment of cutover. The VM's IP address does not change.
- **Migration bandwidth** can be limited via `HyperConverged.spec.liveMigrationConfig.bandwidthPerMigration` to prevent migrations from saturating the cluster network.
- **Post-copy migration** (`allowPostCopy: true`) allows the migration to complete faster by switching to the target node before all pages are copied, then pulling remaining pages on demand. Not recommended for production on edge clusters due to increased network dependency during the post-copy phase.
- **Demo 3 vs Demo 6**: Demo 3 uses local RWO storage and shows restart-based HA (VM waits for original node). Demo 6 uses CephFS RWX storage and shows true live migration (VM moves without downtime). The difference is entirely in the storage backend.

---

## Relationship to Red Hat Recommendations

| Recommendation | This Demo | Notes |
|---|---|---|
| RWX shared storage | ✅ ODF CephFS (`ReadWriteMany`) | Hard requirement — met |
| `infrastructureTopology: HighlyAvailable` | ✅ TNF cluster reports HA | Verified in Step 1 |
| Minimum 3 worker nodes | ⚠ 2 schedulable control-plane nodes | Recommendation, not hard block. Functional on 2-node TNF but not production-recommended. |
| `evictionStrategy: LiveMigrateIfPossible` | ✅ Set in VM spec | Falls back to restart if migration fails |

---

## Cleanup

```bash
oc delete project live-migration-demo
```

The CephFS PVC will be deleted with the namespace. No manual PV cleanup is required
(unlike the local PVs in Demo 3).

---

## Why This Matters

Live migration is the cornerstone of VM HA in traditional virtualization (VMware
vSphere, RHEV). This demo shows that OpenShift can deliver the same capability
alongside containerised workloads on minimal two-node edge hardware — without a
separate hypervisor or additional infrastructure.

**Demo 3 vs Demo 6 in one sentence**: Demo 3 shows that VMs *survive* hardware
failure (restart-based HA). Demo 6 shows that VMs can be *moved* between nodes
with zero downtime (live migration).

Both capabilities run on the same TNF cluster, on the same two nodes, at the
same time.

---

## References

- [OpenShift Virtualization — Live Migration Documentation](https://docs.openshift.com/container-platform/latest/virt/live_migration/virt-about-live-migration.html)
- [Live Migration Requirements](https://docs.openshift.com/container-platform/latest/virt/install/preparing-cluster-for-virt.html#virt-live-migration-requirements_preparing-cluster-for-virt)
- [Configuring Live Migration Limits (HyperConverged CR)](https://docs.openshift.com/container-platform/latest/virt/live_migration/virt-configuring-live-migration.html)
- [ADR-008: ODF Pool Replica Strategy](../../adrs/008-odf-tnf-pool-replica-strategy.md)
- [ADR-009: ODF Post-Install Tuning](../../adrs/009-odf-tnf-post-install-tuning.md)
- [Demo 3: OpenShift Virtualization (restart-based HA)](../03-openshift-virtualization/README.md)
- [Demo 5: DRBD Edge Storage (ODF prerequisite)](../05-drbd-edge-storage/README.md)
