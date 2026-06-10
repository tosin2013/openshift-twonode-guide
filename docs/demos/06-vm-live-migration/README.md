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
    volumeMode: Filesystem
    resources:
      requests:
        storage: 10Gi
EOF

# Monitor the import progress
oc -n live-migration-demo get datavolume fedora-vm-disk -w
# Wait for PHASE: Succeeded (3–10 minutes depending on download speed)
```

> **Why `Filesystem` volume mode?** The ODF CephFS StorageClass
> (`ocs-storagecluster-cephfs`) StorageProfile reports `volumeMode: Filesystem`
> as its supported access mode. `Block` mode is not supported by the CephFS CSI
> provisioner in ODF 4.x — use the RBD StorageClass if `Block` + `RWX` is
> required (requires ODF multi-node pool config).

> **Import time**: The Fedora Cloud image is ~400 MB and takes 3–10 minutes to
> import depending on download speed. For a faster proof-of-mechanism demo that
> skips Step 6 console validation, CirrOS (~20 MB, ~45s import) can be substituted
> — replace the URL with
> `https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img`
> and set `storage: 2Gi`. CirrOS lacks QEMU guest agent so Step 6 uses timing
> analysis only (see Known Issue #5).

---

## Step 3: Create the VirtualMachine

```bash
# Export the bastion SSH public key so it can be injected into the VM
SSH_PUB_KEY=$(cat ~/.ssh/openshift-twonode-ed25519.pub)

# Note: heredoc uses <<EOF (no quotes) so ${SSH_PUB_KEY} is expanded
oc apply -f - <<EOF
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
              user: fedora
              password: fedora
              chpasswd:
                expire: false
              ssh_authorized_keys:
                - ${SSH_PUB_KEY}
              packages:
                - qemu-guest-agent
              runcmd:
                - systemctl enable --now qemu-guest-agent
                - while true; do echo "\$(date): alive on \$(hostname)" >> /tmp/heartbeat.log; sleep 5; done
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

## Step 5b: Maintenance-Driven Migration — Cordon + `virtctl migrate`

This simulates a planned node maintenance window. On TNF, all nodes are
schedulable control-plane nodes that host guard pods (`etcd-guard`,
`kube-apiserver-guard`, etc.) with no owner references. `oc adm drain` requires
`--force` to handle these guard pods, which bypasses KubeVirt's PodDisruptionBudget
and races against the live migration — causing the migration target pod to be
evicted mid-flight. The safe procedure on TNF is:

1. **Cordon** the node (marks `SchedulingDisabled`)
2. **Migrate** all VMs off using `virtctl migrate`
3. **Drain** remaining non-VM workloads with `--force` (VMs are already gone)
4. **Uncordon** when maintenance is complete

```bash
# Record the baseline
DRAIN_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
PRE_DRAIN_NODE="${DRAIN_NODE}"
PRE_DRAIN_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')
echo "VM on: ${DRAIN_NODE}  UID: ${PRE_DRAIN_UID}"

# Step 1: Cordon — mark node unschedulable (simulates maintenance start)
oc adm cordon ${DRAIN_NODE}
oc get nodes  # Expected: DRAIN_NODE shows Ready,SchedulingDisabled

# Step 2: Migrate the VM off the cordoned node
virtctl migrate -n live-migration-demo fedora-live-migrate
# Output: VM fedora-live-migrate was scheduled to migrate

# Watch the migration
oc -n live-migration-demo get vmim -w
# Expected: new VMIM progresses Pending → Scheduling → Running → Succeeded
```

After migration succeeds:

```bash
# Confirm the VM moved
POST_DRAIN_NODE=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.nodeName}')
POST_DRAIN_UID=$(oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.metadata.uid}')

echo "Node before cordon: ${PRE_DRAIN_NODE}"
echo "Node after migrate: ${POST_DRAIN_NODE}"
[[ "$PRE_DRAIN_NODE" != "$POST_DRAIN_NODE" ]] && \
  echo "✅ VM migrated off the cordoned node" || \
  echo "⚠️  VM is still on the same node"

[[ "$PRE_DRAIN_UID" == "$POST_DRAIN_UID" ]] && \
  echo "✅ Same UID — live migration confirmed" || \
  echo "⚠️  Different UID — VM was restarted (check evictionStrategy)"

# Step 3 (optional): Drain remaining pods for maintenance
# VM is already gone — force is safe at this point
oc adm drain ${DRAIN_NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=60s 2>&1 | grep -v "error.*guard"  # guard pod errors are expected
# Note: guard pod eviction errors are expected and harmless on TNF

# Step 4: Uncordon when maintenance is complete
oc adm uncordon ${DRAIN_NODE}
oc get nodes
# Expected: both nodes Ready, SchedulingDisabled removed
```

---

## Step 6: Validate Heartbeat Continuity

The VM runs a heartbeat loop writing timestamps to `/tmp/heartbeat.log` every 5 seconds
(set up in the cloud-init `userData`). If live migration succeeded with zero downtime,
the heartbeat log should have no gaps.

```bash
# Wait for qemu-guest-agent to be ready (Fedora installs it via cloud-init ~2 min)
oc -n live-migration-demo get vmi fedora-live-migrate \
  -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'
# Expected: True (may take 2 minutes after VM boot while dnf installs qemu-guest-agent)

# SSH into the VM via virtctl port-forward + bastion key
virtctl port-forward -n live-migration-demo vm/fedora-live-migrate 2222:22 &
PF_PID=$!
sleep 3

ssh -i $SSH_KEY \
    -p 2222 \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    fedora@127.0.0.1 \
    "wc -l /tmp/heartbeat.log && echo '---' && tail -10 /tmp/heartbeat.log"

kill $PF_PID
```

Expected output — continuous 5-second entries with no gaps across migration timestamps:
```
204
---
Tue Jun  9 12:00:00 UTC 2026: alive on fedora-live-migrate
Tue Jun  9 12:00:05 UTC 2026: alive on fedora-live-migrate
Tue Jun  9 12:00:10 UTC 2026: alive on fedora-live-migrate  ← migration happened here
Tue Jun  9 12:00:15 UTC 2026: alive on fedora-live-migrate  ← no gap = zero downtime
```

Verify the entry count matches expected uptime:
```bash
# entries ≈ vm_uptime_seconds / 5
# A restart resets the file — unchanged entry count across migrations = live migration confirmed
```

> **Migration duration cross-check**: Both migrations on this topology completed in
> 3–4 seconds — less than one heartbeat interval. You can verify this independently:
>
> ```bash
> oc -n live-migration-demo get vmim -o json | python3 -c "
> import json,sys
> from datetime import datetime
> d=json.load(sys.stdin)
> for it in d['items']:
>   ms=it.get('status',{}).get('migrationState',{})
>   start,end=ms.get('startTimestamp',''),ms.get('endTimestamp','')
>   if start and end:
>     dur=(datetime.strptime(end,'%Y-%m-%dT%H:%M:%SZ')-datetime.strptime(start,'%Y-%m-%dT%H:%M:%SZ')).seconds
>     print(f'{it[\"metadata\"][\"name\"]}: {it[\"status\"][\"phase\"]}  duration={dur}s')
> "
> # Example: kubevirt-migrate-vm-xxxxx: Succeeded  duration=3s
> ```

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

| Check | Expected Result | Validated |
|---|---|---|
| `LiveMigratable` condition on VMI | `True` before any migration | ✅ `True` + `StorageLiveMigratable: True` |
| `virtctl migrate` result | VMIM reaches `Succeeded` | ✅ Succeeded in 3–4 seconds |
| VM node after manual migration | Different from pre-migration node | ✅ node2→node1 confirmed |
| VMI UID after manual migration | **Unchanged** — confirms live migration | ✅ Same UID |
| Heartbeat log continuity | No gaps — `wc -l` unchanged, no time gap | ✅ Both migrations < 5s (< 1 heartbeat interval) |
| VM node after cordon+migrate | Migrated to non-cordoned node | ✅ node1→node2 confirmed |
| Cluster operators after test | All `Available`, no `Degraded` | ✅ 10/10 preflight signals pass |

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

### 4. `oc adm drain` — Guard Pod Race Condition on TNF

**Symptom**: Live migration fails with `Migration target pod was removed during active
migration`. The migration VMIM shows `Failed` after being in `PreparingTarget` briefly.

**Cause**: TNF control-plane nodes host guard pods (`etcd-guard`,
`kube-apiserver-guard`, etc.) with no owner references. `oc adm drain` requires
`--force` to handle these, which bypasses KubeVirt's PodDisruptionBudget. The
`--force` flag then evicts the source `virt-launcher` pod before the migration can
complete, killing the target pod mid-handshake.

**Fix**: Always pre-migrate VMs before draining on TNF. See Step 5b above for the
cordon → migrate → drain sequence. The key: ensure all VMs are off the node before
running `oc adm drain --force`.

---

### 5. CirrOS Lacks QEMU Guest Agent — Console Heartbeat Not Accessible

**Symptom**: `virtctl guestosinfo` returns `VMI does not have guest agent connected`.
SSH via `virtctl port-forward` fails with permission denied.

**Cause**: CirrOS is a minimal debug image without `qemu-guest-agent` or standard
SSH key injection support. The cloud-init `password:` directive sets a console
password but CirrOS dropbear SSH blocks password authentication by default.

**Fix**: Use Fedora Cloud or RHEL images for the full Step 6 console validation.
CirrOS is suitable for verifying the migration mechanism (Steps 1–5) but not for
direct heartbeat log inspection. Use the migration timing analysis described in
Step 6 as an equivalent indirect proof.

---

### 6. CephFS `volumeMode: Block` Not Supported

**Symptom**: DataVolume fails to bind or CDI reports an incompatible access mode.

**Cause**: The `ocs-storagecluster-cephfs` StorageProfile reports only
`volumeMode: Filesystem` + `accessModes: [ReadWriteMany]`. The CephFS CSI driver
in ODF 4.x does not support `Block` volume mode. Block+RWX requires the RBD
StorageClass with a multi-node pool configuration.

**Fix**: Use `volumeMode: Filesystem` (already corrected in Step 2 above). VM disks
stored as files in a CephFS Filesystem PVC work correctly for live migration.

---

### 7. OSD CPU Requests Reconciled Back by Rook Operator

**Symptom**: After manually patching `rook-ceph-osd-*` Deployments to reduce init
container CPU from 2000m to 200m, node CPU allocation returns to 97–99% after a
few minutes.

**Cause**: The Rook operator periodically reconciles OSD Deployments and overwrites
manual Deployment patches with the spec from the CephCluster CR. To make the
change persistent, you must patch the CephCluster CR `spec.resources.osd`:

```bash
oc -n openshift-storage patch cephcluster ocs-storagecluster-cephcluster \
  --type=merge \
  -p '{
    "spec": {
      "resources": {
        "osd": {
          "requests": {"cpu": "200m", "memory": "512Mi"},
          "limits": {"cpu": "1", "memory": "4Gi"}
        },
        "prepareosd": {
          "requests": {"cpu": "200m", "memory": "200Mi"},
          "limits": {"cpu": "500m", "memory": "200Mi"}
        }
      }
    }
  }'
```

Then manually restart the OSD pods to pick up the new spec. The CephCluster patch
persists across Rook reconciliation loops; the Deployment patch alone does not.

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
