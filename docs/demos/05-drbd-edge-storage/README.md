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

This validation uses a persistent **heartbeat counter application** — a stateful Deployment
that continuously writes incrementing records to an ODF RBD PVC and serves the count over HTTP.
This lets you watch data persist through a fence event in real time, the same way Demo 1's POS
service lets you watch stateless failover.

### Step 1: Deploy the Heartbeat Counter Application

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

oc new-project drbd-demo

oc apply -f - <<'EOF'
# PVC backed by ODF/DRBD RBD StorageClass
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: drbd-counter-pvc
  namespace: drbd-demo
spec:
  storageClassName: ocs-storagecluster-ceph-rbd
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
# Heartbeat counter: writes a new line to /data/counter.log every 2s
# and serves the current line count + last entry over HTTP port 8080
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drbd-counter
  namespace: drbd-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: drbd-counter
  template:
    metadata:
      labels:
        app: drbd-counter
    spec:
      containers:
        - name: counter
          # busybox:1.36 is required — ubi-minimal lacks 'nc' and 'hostname'
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /data
              # Writer: append a timestamped entry every 2 seconds
              while true; do
                COUNT=$(wc -l < /data/counter.log 2>/dev/null || echo 0)
                echo "$((COUNT + 1)) $(date -u +%Y-%m-%dT%H:%M:%SZ) node=$(hostname)" \
                  >> /data/counter.log
                sleep 2
              done &
              # HTTP server: return last entry and total count
              while true; do
                COUNT=$(wc -l < /data/counter.log 2>/dev/null || echo 0)
                LAST=$(tail -1 /data/counter.log 2>/dev/null || echo "no data yet")
                BODY="count=${COUNT} last=${LAST}"
                printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: text/plain\r\n\r\n%s' \
                  "${#BODY}" "$BODY" | nc -l -p 8080 2>/dev/null || true
              done
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 3
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: drbd-counter-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: drbd-counter
  namespace: drbd-demo
spec:
  selector:
    app: drbd-counter
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: drbd-counter
  namespace: drbd-demo
spec:
  to:
    kind: Service
    name: drbd-counter
  port:
    targetPort: 8080
EOF

# Wait for the pod to be Running
oc -n drbd-demo rollout status deployment/drbd-counter

# Confirm which node it landed on
oc -n drbd-demo get pods -o wide
```

### Step 2: Start the Availability Monitor

Open a **second terminal** and run this loop. Leave it running throughout the fence test.

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

COUNTER_URL="http://$(oc -n drbd-demo get route drbd-counter -o jsonpath='{.spec.host}')"
echo "Monitoring: ${COUNTER_URL}"

# Poll every 3 seconds — shows HTTP status, counter value, and which node is serving
while true; do
  RESPONSE=$(curl -s --max-time 5 "${COUNTER_URL}" 2>/dev/null)
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${COUNTER_URL}" 2>/dev/null)
  NODE=$(oc -n drbd-demo get pod -l app=drbd-counter \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "none")
  echo "$(date +%H:%M:%S) — HTTP ${STATUS} — node:${NODE} — ${RESPONSE}"
  sleep 3
done
```

A healthy baseline looks like:
```
14:02:10 — HTTP 200 — node:openshift-node1 — count=45 last=45 2026-06-09T14:02:10Z node=drbd-counter-...
14:02:13 — HTTP 200 — node:openshift-node1 — count=46 last=46 2026-06-09T14:02:13Z node=drbd-counter-...
```

The counter must be **incrementing continuously** before you proceed to the fence.

### Step 3: Pre-Flight Health Check

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Run the full ODF pre-flight — all checks must pass
bash scripts/tnf-preflight-validate.sh --odf
# Expected: "PREFLIGHT PASSED" (Signals 1–10 all green or warning-only)

# Record the counter value before fencing
PRE_FENCE_COUNT=$(curl -s --max-time 5 \
  "http://$(oc -n drbd-demo get route drbd-counter -o jsonpath='{.spec.host}')" \
  2>/dev/null | grep -o 'count=[0-9]*' | cut -d= -f2)
echo "Counter before fence: ${PRE_FENCE_COUNT}"

# Confirm Pacemaker is healthy
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Expected: Online: [ openshift-node1 openshift-node2 ], no Failed Resource Actions
```

### Step 4: Set stonith-action=off (KVM Only)

> This keeps node1 powered off after fencing so you have time to verify DRBD promotion
> and data access on node2 before node1 returns. Do NOT skip this on KVM — the default
> `stonith-action=reboot` causes node1 to return in ~90 seconds, which is not enough
> time to verify a clean cross-node PVC mount.
>
> Do NOT change this on bare-metal production clusters.
>
> **KVM + Redfish caveat (OCP 4.22.0-rc.5)**: On KVM environments using the Redfish
> fence agent, `stonith-action=off` may be silently ignored and the node may still
> reboot. This was observed during validation but has not been confirmed as a bug —
> it is not yet validated on bare-metal or against the GA release. If the node reboots
> immediately after fencing, apply out-of-service taints right away and proceed;
> the data integrity test remains valid.

```bash
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs property set stonith-action=off
```

### Step 5: Fence Node 1

> ⚠ **Critical order**: Fence BEFORE applying `out-of-service` taints. Applying taints
> to a live node causes the etcd-operator to remove it from membership →
> `panic: removed all voters` → complete API outage.
> See [ADR-011](../../adrs/011-odf-tnf-demo5-fencing-procedure.md).

```bash
# Note: the correct command is 'pcs stonith fence', not 'pcs node fence'
ssh -i $SSH_KEY core@192.168.49.22 \
  sudo pcs stonith fence openshift-node1
# Expected output: "Node: openshift-node1 fenced"

# Watch node1 go NotReady (API may pause ~15-20s during etcd quorum transition)
for i in $(seq 1 18); do
  STATUS=$(oc get node openshift-node1 --no-headers 2>/dev/null | awk '{print $2}')
  echo "$(date +%H:%M:%S) openshift-node1=${STATUS:-API-timeout}"
  [[ "$STATUS" == "NotReady" ]] && echo "✅ node1 is NotReady — fenced" && break
  sleep 10
done
```

**In your monitor terminal** you will see:
- `HTTP 000` — API briefly down during etcd `force-new-cluster` (~15–20 seconds)
- `HTTP 200` returns with the **counter still incrementing from node2** once the pod reschedules
- Counter value should be **greater than** `${PRE_FENCE_COUNT}` (no data lost)

### Step 6: Apply Out-of-Service Taints

Apply taints **only after** node1 shows `NotReady` — this signals Kubernetes to evict pods
and allows the RBD PVC to re-attach to node2.

```bash
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule

# Watch the counter pod reschedule to node2
oc -n drbd-demo get pods -o wide -w
# Expected: drbd-counter-xxx Terminating on node1 → Running on node2
```

> **Note on RBD re-attach timing**: After the pod reschedules, it may take 30–60 seconds for
> the RBD volume to fully detach from node1's attachment record and re-attach to node2.
> The pod will show `ContainerCreating` during this window. This is normal — the
> `VolumeAttachment` object for the PV transitions `Attached: false → true` as the CSI
> driver completes the hand-off.

### Step 7: Verify Data Integrity After Failover

Once the counter pod is Running on node2, verify the data survived:

```bash
# Confirm pod is on node2
oc -n drbd-demo get pods -o wide | grep drbd-counter

# Check the counter resumed incrementing (no reset to 0)
POST_FENCE_COUNT=$(curl -s --max-time 5 \
  "http://$(oc -n drbd-demo get route drbd-counter -o jsonpath='{.spec.host}')" \
  2>/dev/null | grep -o 'count=[0-9]*' | cut -d= -f2)
echo "Counter before fence: ${PRE_FENCE_COUNT}"
echo "Counter after fence:  ${POST_FENCE_COUNT}"
[[ "${POST_FENCE_COUNT}" -gt "${PRE_FENCE_COUNT}" ]] && \
  echo "✅ PASS: counter continued from pre-fence value — data intact" || \
  echo "❌ FAIL: counter reset or dropped — data loss!"

# Verify the log file on the PVC is intact
oc -n drbd-demo exec deploy/drbd-counter -- \
  sh -c 'echo "Total entries: $(wc -l < /data/counter.log)" && tail -3 /data/counter.log'
# Expected: entries from both before AND after the fence (no gap in sequence numbers)
```

### Step 8: Restore Node 1 and Verify Re-sync

```bash
# Power node1 back on via Pacemaker (reverses the stonith-action=off we set in Step 4)
ssh -i $SSH_KEY core@192.168.49.22 \
  sudo pcs stonith unstandby openshift-node1 2>/dev/null || \
  sudo virsh start openshift-node1 2>/dev/null

# Wait for node1 to return Ready
for i in $(seq 1 18); do
  STATUS=$(oc get node openshift-node1 --no-headers 2>/dev/null | awk '{print $2}')
  echo "$(date +%H:%M:%S) openshift-node1=${STATUS:-waiting}"
  [[ "$STATUS" == "Ready" ]] && echo "✅ node1 Ready" && break
  sleep 10
done

# Remove out-of-service taints
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
oc adm taint nodes openshift-node1 \
  node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule-

# Restore stonith-action to reboot for normal operation
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs property set stonith-action=reboot

# Clear Pacemaker failed resource history
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup

# Wait for both nodes and etcd to be fully healthy
oc get nodes
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep etcd
```

### Step 9: Cleanup

```bash
oc delete project drbd-demo
```

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
| PVC bind time | < 10 seconds |
| Counter app uptime | HTTP 200 within ~30s of fence (brief gap during etcd quorum transition) |
| Counter value after failover | Greater than pre-fence value — no reset to zero |
| PVC re-attach to node2 | `VolumeAttachment` transitions `Attached: false → true` within 60s |
| DRBD re-sync after node recovery | Both nodes return to `UpToDate` |

---

## Validated Results (June 9, 2026)

Validated against OCP 4.22.0-rc.5 TNF cluster on KVM/IBM Cloud with ODF 4.21 Developer Preview.

| Check | Expected | Actual |
|---|---|---|
| PVC bind time | < 10s | **< 5s** |
| `ocs-storagecluster-ceph-rbd` PVC writeable | Yes | **Yes** — SHA256 write/read verified across nodes |
| Cross-node data integrity | Checksum match | **Match confirmed** — data written on node1 read from node2 |
| STONITH fence command | `pcs stonith fence` | **`pcs stonith fence`** — `pcs node fence` is wrong syntax on pcs 0.11+ |
| Fence execution | Node powered off | **node1 fenced** — confirmed "Node: openshift-node1 fenced" |
| API recovery after fence | ~2-3 min | **~3 minutes** |
| RBD volume re-attach to node2 | < 60s | **~50s** (`VolumeAttachment Attached: false → true`) |
| etcd recovery post-fence | Automatic via Pacemaker | **Requires `pcs resource cleanup` + recovery script** — see below |
| `StorageCluster` phase shows `Error` | Expected (known ODF 4.21 DP quirk) | **Confirmed** — storage is fully functional despite `Error` phase |

### Observed Fence Sequence (June 9, 2026)

```
14:07:29  pcs stonith fence openshift-node1 → "Node: openshift-node1 fenced"
14:07:29  API timeout begins (etcd quorum transition)
14:10:46  API back — both nodes Ready
14:11:xx  out-of-service taints applied to node1
14:12:xx  Counter pod rescheduled to node2 (ContainerCreating ~50s while RBD re-attaches)
14:13:xx  Counter pod Running on node2
14:13:xx  ✅ Data verified: checksum match, counter continued from pre-fence value
```

### Known Issues Discovered During Validation

| Issue | Impact | Fix / Note |
|---|---|---|
| `pcs node fence` invalid on pcs 0.11+ | Fence silently does nothing | Use `pcs stonith fence` |
| `stonith-action=reboot` (KVM default) | Node reboots in ~90s instead of staying off | Set `stonith-action=off` before the demo (Step 4) |
| `stonith-action=off` may be ignored by Redfish fence agent on KVM | Node reboots despite `off` setting | Observed on KVM + Redfish under OCP 4.22.0-rc.5. **Not confirmed as a bug** — not yet validated on bare-metal or GA release. Mitigation: apply out-of-service taints immediately after fence returns. |
| `ubi-minimal` image lacks `nc` and `hostname` | Counter app never becomes Ready; readiness probe always fails | Use `busybox:1.36` — corrected in Step 1 |
| RBD CSI driver not immediately re-registered after node reboot | Pod stays in `ContainerCreating` for 2–4 min after re-attach (longer than 60s nominal) | Normal after a fence-triggered reboot. Wait; do not force-delete. CSI nodeplugin re-registers once kubelet restarts. |
| Force-deleting RBD pods (`--force --grace-period=0`) leaves stale CSI lock | Next pod mount blocked for 5+ minutes | Let pods exit naturally; see Troubleshooting below |
| ctrlplugin deployments default to `replicas: 2` | Doubles CPU usage, can push nodes to 90%+ CPU | Fixed in `scripts/update-csi-resources.sh` (adds `replicas: 1`) |
| Post-fence etcd recovery requires manual `pcs resource cleanup` + recovery script | Cluster not self-healing after fence | Run `scripts/etcd-pacemaker-recovery.sh` — see ADR-011 |
| kube-scheduler stale leader lease after etcd snapshot restore | All pods cluster-wide stuck `Pending` indefinitely | Delete the stale lease: `oc delete lease kube-scheduler -n openshift-kube-scheduler`. New leader acquires in ~15s. |

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

### RBD PVC stuck in ContainerCreating after force-deleting a pod

**Symptom**: After force-deleting (`--force --grace-period=0`) a pod that used an RBD-backed PVC,
subsequent pods mounting the same PVC hang in `ContainerCreating` with:
```
MountVolume.MountDevice failed: rpc error: code = Aborted
  desc = an operation with the given Volume ID ... already exists
```

**Root cause**: Force-deleting a pod skips the graceful CSI volume unmount. The RBD CSI node
plugin retains an in-progress operation entry for the volume ID. The next mount attempt finds
the operation still "active" and aborts.

**Fix**: Wait 5 minutes for the CSI operation timeout to expire, then delete and recreate the
stuck pod:
```bash
# Delete the stuck pod (gracefully, not force)
oc delete pod <stuck-pod> -n default

# Wait for the 5-minute CSI operation timeout
sleep 300

# Recreate the pod
oc run drbd-reader ... 
```

**Prevention**: Never use `--force --grace-period=0` on pods that have RBD PVCs. Let the pod
exit naturally (`oc wait pod/<name> --for=condition=Ready=false --timeout=60s`) before the fence.

### Fence command: pcs node fence vs pcs stonith fence

On RHEL 9 with pcs 0.11+, the command to fence a node is `pcs stonith fence <node>`, not
`pcs node fence <node>`. Using the wrong subcommand prints the help text and does nothing.

```bash
# Correct (RHEL 9, pcs 0.11+):
sudo pcs stonith fence openshift-node1

# Wrong (pcs 0.10 syntax — does nothing on newer pcs):
sudo pcs node fence openshift-node1
```

### Node returns too quickly after fence — can't verify DRBD promotion window

The default Pacemaker `stonith-action` for KVM deployments is `reboot`. This means after
`pcs stonith fence`, node1 is power-cycled and returns in ~2-3 minutes. To observe DRBD
promotion and verify data access from node2 before node1 recovers, you must:

1. Act immediately after the fence command returns ("Node: openshift-node1 fenced")
2. The window is ~2-3 minutes before node1 comes back online
3. Apply out-of-service taints immediately, then run the reader pod

Alternatively, to keep node1 off for longer testing:
```bash
# After fencing, prevent node1 from starting Pacemaker resources:
sudo pcs node standby openshift-node1
# Then test...
# Restore when done:
sudo pcs node unstandby openshift-node1
```

> **OCP 4.22.0-rc.5 / KVM + Redfish observation**: `stonith-action=off` was observed to be
> ignored by the Redfish fence agent on this environment — the node rebooted rather than
> powering off. This has not been confirmed as a bug and is not yet validated on bare-metal
> or against the GA release. The `pcs node standby` workaround above is more reliable for
> extending the test window on KVM.

### All pods stuck Pending after etcd snapshot restore

**Symptom**: After recovering the cluster from an etcd snapshot restore, newly created pods
(and existing Pending pods) never leave `Pending` state. The kube-scheduler logs only show
one pod being retried every 5 minutes and no other scheduling activity.

**Root cause**: The kube-scheduler's leader lease in etcd was held by an old container
instance that no longer exists. The new scheduler container cannot acquire the lease until
the old one expires (up to 137 seconds). If the old container exited cleanly, the lease is
never renewed and the new scheduler is blocked.

**Fix**:
```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

# Check the current lease holder
oc get lease kube-scheduler -n openshift-kube-scheduler \
  -o jsonpath='Holder: {.spec.holderIdentity}{"\n"}'

# Delete the stale lease — the active scheduler acquires it within ~15 seconds
oc delete lease kube-scheduler -n openshift-kube-scheduler

# Verify new leader acquired (holderIdentity will change)
sleep 15
oc get lease kube-scheduler -n openshift-kube-scheduler \
  -o jsonpath='New holder: {.spec.holderIdentity}{"\n"}'
```

All pending pods will begin scheduling within seconds of the new leader acquiring the lease.

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
