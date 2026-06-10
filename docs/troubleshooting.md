# Troubleshooting Guide — Two-Node OpenShift with Fencing (TNF)

This guide covers the most common failure modes encountered when deploying and operating a TNF cluster.

---

## Table of Contents

1. [Fencing Agent Misconfiguration](#1-fencing-agent-misconfiguration)
2. [etcd Failing to Form Quorum](#2-etcd-failing-to-form-quorum)
3. [Slow Disk Latency Warnings](#3-slow-disk-latency-warnings)
4. [Pacemaker Resource Failures](#4-pacemaker-resource-failures)
5. [Installation Failures](#5-installation-failures)
6. [OVNKubernetes Networking Issues](#6-ovnkubernetes-networking-issues)
7. [Cluster Recovery After Total Outage](#7-cluster-recovery-after-total-outage)
8. [ODF + Demo 5 Specific Issues](#8-odf--demo-5-specific-issues)
9. [cert-manager Issues](#9-cert-manager-issues)

---

## 1. Fencing Agent Misconfiguration

### Symptom: STONITH resource fails to start or shows `Stopped`

```bash
sudo pcs status
# Shows: fence-node2 (stonith:fence_redfish): Stopped
# Or: FAILED: fence-node2
```

### Diagnosis

```bash
# Check STONITH agent logs
sudo journalctl -u pacemaker --since "1 hour ago" | grep -i stonith

# Test the fencing agent manually (must be run from the node that owns the resource)
sudo fence_redfish \
  -a <bmc-ip> \
  -l <bmc-user> \
  -p <bmc-password> \
  -b "/redfish/v1/Systems/<system-id>" \
  -o status

# For KVM / sushy-tools:
sudo fence_redfish \
  -a localhost \
  --ssl-insecure \
  -l admin \
  -p changeme \
  -b "/redfish/v1/Systems/<vm-uuid>" \
  -o status
```

### Common Causes and Fixes

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` | BMC IP unreachable or sushy-tools not running | Check firewall; `systemctl status sushy-emulator` |
| `Authentication failed` | Wrong BMC credentials | Verify `-l` and `-p` parameters match BMC config |
| `Systems URI not found` | Wrong Redfish Systems path | Use `curl http://<bmc-ip>/redfish/v1/Systems/` to discover the correct URI |
| `SSL certificate error` | Self-signed BMC cert | Add `--ssl-insecure` flag or import the BMC CA certificate |
| sushy-tools returns 404 | VM UUID changed | Re-run `virsh domuuid <vm-name>` and update the STONITH resource |

### Updating STONITH Resource Configuration

```bash
# Update the BMC address for the fence-node2 STONITH resource
sudo pcs stonith update fence-node2 ipaddr="<new-bmc-ip>"

# Update the systems URI
sudo pcs stonith update fence-node2 systems_uri="/redfish/v1/Systems/<new-id>"

# Restart the STONITH resource after changes
sudo pcs stonith cleanup fence-node2
```

### Fencing Timeout Tuning

Real BMC power-off operations are slower than KVM libvirt power-off. If `fence_redfish` times out before the BMC responds:

```bash
# Increase timeouts for a real BMC (default: power_timeout=40, login_timeout=20)
sudo pcs stonith update fence-node2 \
  power_timeout=60 \
  login_timeout=30 \
  delay=0
```

> **Note**: Do not set `delay` symmetrically on both STONITH resources. A delay asymmetry on one resource prevents simultaneous fencing races.

---

## 2. etcd Failing to Form Quorum

### Symptom: etcd container fails to start or reports unhealthy

```bash
sudo podman ps | grep etcd
# Container not running or repeatedly restarting

sudo pcs status
# etcd resource shows Failed or Stopped
```

### Symptom: API server cannot reach etcd

```bash
oc get nodes
# Error from server: etcdserver: request timed out
# or: Error from server (ServiceUnavailable): the server is currently unable to handle the request
```

### Diagnosis

```bash
# Check etcd container logs
sudo podman logs etcd --tail=50

# Check if etcd data directory is accessible and not corrupted
sudo ls -lh /var/lib/etcd/
sudo file /var/lib/etcd/member/wal/*.wal 2>/dev/null | head -5

# Check etcd member list from inside the container
sudo podman exec etcd etcdctl member list \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).key

# Check Pacemaker etcd resource status and constraints
sudo pcs resource show
sudo pcs constraint show
```

### Cause: etcd Failed to Promote After Fencing

If Pacemaker fenced a node but etcd on the surviving node did not enter single-member mode:

```bash
# Force etcd into single-member cluster mode (use with caution — only after fencing confirms the other node is OFF)
sudo podman stop etcd

# Edit the etcd start script to add --force-new-cluster
# The exact path depends on the two-node-toolbox configuration:
sudo grep -r "force-new-cluster" /etc/pacemaker/ /etc/systemd/

# After force-new-cluster, re-add the second member when node recovers
sudo podman exec etcd etcdctl member add node2 \
  --peer-urls="https://<node2-ip>:2380" \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).key
```

### Cause: STONITH Failed — Cluster Frozen as a Safety Measure

**This is expected behavior, not a bug.** If Pacemaker cannot confirm the failed node is powered off (STONITH failed), it will NOT promote etcd on the surviving node. This prevents split-brain.

```bash
# Check if STONITH failure is the root cause
sudo journalctl -u pacemaker | grep -i "stonith\|fencing" | tail -20

# Manually power off the failed node, then clear the STONITH failure
sudo pcs stonith cleanup fence-node2
sudo pcs resource cleanup etcd
```

---

## 3. Slow Disk Latency Warnings

### Symptom: etcd logs show fsync latency warnings

```
etcd: slow fdatasync ... took too long (Xms) on leader, expect leader to slow down or benchmark your disk
```

Or in Kubernetes events:
```
etcd leader is currently electing a new leader; please retry
```

### Why This Matters for TNF

etcd in TNF runs as a Podman container with the data directory on the host filesystem. etcd is extremely I/O latency sensitive — it commits every Raft log entry with an `fdatasync()` call. If the disk cannot respond within ~10ms at the 99th percentile, etcd becomes unstable and may trigger spurious leader elections.

### Diagnosis

```bash
# Run the fio disk benchmark Red Hat recommends for etcd
# Run this from the host (not inside the container) on the etcd data disk
sudo fio \
  --rw=write \
  --ioengine=sync \
  --fdatasync=1 \
  --directory=/var/lib/etcd \
  --size=22m \
  --bs=2300 \
  --name=etcd-test \
  --output-format=json | python3 -c "
import sys, json
data = json.load(sys.stdin)
job = data['jobs'][0]
p99 = job['sync']['lat_ns']['percentile']['99.000000']
print(f'99th percentile fdatasync latency: {p99/1000:.2f}ms')
print('OK' if p99 < 10000000 else 'SLOW — consider moving etcd to NVMe')"

# Check current disk I/O scheduler
cat /sys/block/sda/queue/scheduler

# Check I/O utilization
iostat -x 1 5
```

### Fixes

| Fix | When to Apply |
|---|---|
| Move etcd data directory to a dedicated NVMe | Persistent slow disk — most effective fix |
| Set I/O scheduler to `none` (for NVMe) or `mq-deadline` (for HDD/SSD) | Scheduler mismatch |
| Enable `ionice` prioritization for the etcd container | Shared disk with competing workloads |
| Increase etcd heartbeat interval | Temporary mitigation — does not fix underlying latency |

```bash
# Change I/O scheduler for the etcd disk (NVMe)
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler

# Make persistent across reboots
cat <<'EOF' | sudo tee /etc/udev/rules.d/60-etcd-scheduler.rules
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
```

---

## 4. Pacemaker Resource Failures

### Symptom: Pacemaker resource stuck in `FAILED` state

```bash
sudo pcs status
# etcd:0 (ocf::heartbeat:...) FAILED node1
```

### Clear a Failed Resource

```bash
# Clear the failure count and allow Pacemaker to retry
sudo pcs resource cleanup etcd

# If a specific node, target that node
sudo pcs resource cleanup etcd node=node1
```

### Symptom: Node shows `OFFLINE` in `pcs status` but is actually running

```bash
# Check Corosync ring status
sudo corosync-cfgtool -s

# Restart Corosync if ring is faulty
sudo systemctl restart corosync

# If node is genuinely offline but recovered, try to bring it back
sudo pcs node unstandby node2
```

### Symptom: Pacemaker cluster has no quorum

```bash
sudo pcs status
# WARNING: corosync and pacemaker are not running on node2
# Cluster partition: with quorum (1/2 nodes)
```

This is the expected state when one node is fenced. The surviving node operates without cluster quorum but with `no-quorum-policy=ignore` set during installation, which allows Pacemaker to continue managing resources. This is intentional for a two-node cluster.

### Resource Dependency Issues

If the etcd resource fails to start because STONITH is not yet configured:

```bash
# Verify STONITH is enabled
sudo pcs property show stonith-enabled
# Must be: stonith-enabled: true

# Verify STONITH constraints
sudo pcs constraint order show

# If STONITH resource is missing, recreate it (see deployment guide Section 8.2)
```

---

## 5. Installation Failures

### Symptom: `wait-for bootstrap-complete` times out

```bash
# Check which rendezvous host is being used
grep "rendezvous" clusters/two-node-fencing/agent-config.yaml

# Check agent events from the installer
openshift-install agent wait-for bootstrap-complete \
  --dir clusters/two-node-fencing/ \
  --log-level debug 2>&1 | tail -30

# From the bastion, verify the node is reachable at its planned IP
ping 192.168.150.21
ssh core@192.168.150.21  # SSH is available during installation

# On the node, check agent service logs
sudo journalctl -u agent.service -f
```

### Symptom: Node does not get the expected IP address

This is almost always a MAC address mismatch. The ABI uses MAC-to-IP mappings from `nodes.yml`.

```bash
# From the node's console or virsh console, check the MAC address
ip link show

# From the KVM host
virsh domiflist openshift-node1

# Verify it matches nodes.yml
grep macAddress clusters/two-node-fencing/nodes.yml
```

### Symptom: `wait-for install-complete` hangs on cluster operator

```bash
# Find the stuck operator
oc get clusteroperators | grep -v "True.*False.*False"

# Describe the operator for events
oc describe clusteroperator <name>

# Check the operator's pods
oc get pods -n openshift-<name> | grep -v Running
oc logs -n openshift-<name> <pod-name> --tail=50
```

---

## 6. OVNKubernetes Networking Issues

### Symptom: Pods cannot communicate across nodes

```bash
# Check OVN control plane pods
oc get pods -n openshift-ovn-kubernetes | grep -v Running

# Check OVN northbound and southbound database health
oc -n openshift-ovn-kubernetes exec -it <ovnkube-master-pod> -- ovn-nbctl show 2>/dev/null | head -30

# Test cross-node pod connectivity
oc debug node/node1 -- chroot /host ping -c3 <node2-pod-ip>
```

### Symptom: MTU issues on KVM

This occurs when the libvirt bridge MTU is smaller than the OVN overlay MTU.

```bash
# Check the MTU on the cluster nodes
ip link show

# Check the libvirt bridge MTU on the KVM host
ip link show virbr-twonode

# If there is a mismatch, set the bridge MTU to 9000 (jumbo frames) or reduce OVN MTU
virsh net-edit twonode
# Add: <mtu size='1500'/> inside the <network> block to enforce matching MTU
```

### Symptom: API VIP or Ingress VIP not reachable

```bash
# Check keepalived status on the nodes
oc get pods -n openshift-vsphere-infra 2>/dev/null || \
  oc get pods -n openshift-baremetal-infra 2>/dev/null | grep keepalived

# Verify the VIP is assigned to one of the nodes
ssh core@node1 ip addr show | grep 192.168.150.10
ssh core@node2 ip addr show | grep 192.168.150.10

# One node should have the API VIP; if neither does, restart the haproxy/keepalived pod
oc delete pod -n openshift-baremetal-infra -l app=haproxy
```

---

## 7. Cluster Recovery After Total Outage

If both nodes were simultaneously powered off (e.g., datacenter power loss):

### Step 1: Power on both nodes

Start both nodes at approximately the same time.

### Step 2: Verify Corosync forms

```bash
# SSH to Node 1 once it has booted
ssh core@192.168.150.21
sudo pcs status
# Wait until both nodes appear as Online
```

### Step 3: Check etcd auto-recovery

Pacemaker should automatically restart etcd on both nodes. If it does not:

```bash
sudo pcs resource cleanup etcd
sudo pcs status --full
```

### Step 4: Verify API server

```bash
export KUBECONFIG=clusters/two-node-fencing/auth/kubeconfig
oc get nodes
oc get clusteroperators
```

### Step 5: If etcd data is inconsistent

If both nodes were fenced simultaneously and etcd data is inconsistent, restore from a backup:

```bash
# Identify the most recent etcd backup
ls -lt /var/lib/etcd-backup/

# Restore (follow the two-node-toolbox recovery procedure)
# See: https://github.com/openshift/two-node-toolbox/blob/main/docs/recovery.md
```

> **Best Practice**: Schedule regular etcd backups with a cron job on each node:
> ```bash
> sudo crontab -l
> # Add: 0 */6 * * * /usr/local/bin/etcd-backup.sh
> ```

---

## 8. ODF + Demo 5 Specific Issues

This section covers failure modes specific to the OpenShift Data Foundation + DRBD
deployment (Demo 5) on a two-node TNF cluster. The root cause of each failure is
unique to the two-node topology because there is no quorum margin — any loss of an
etcd member is immediately fatal.

---

### 8.1 `panic: removed all voters` — API Complete Outage After Fence

**Severity: Critical.** This failure causes total loss of the Kubernetes API.

#### Symptom

After applying `node.kubernetes.io/out-of-service` taints to fence a node for ODF
HA validation, the kube-apiserver on the surviving node stops responding:

```bash
oc get nodes
# Error from server: etcdserver: request timed out

# On the surviving node, etcd container log shows:
sudo podman logs etcd 2>&1 | tail -5
# panic: removed all voters; must start leader election again
```

#### Root Cause

The Cluster Etcd Operator (CEO) watches `out-of-service` taints independently of
Pacemaker. When it sees a taint on node2, CEO removes node2 from the etcd member
list via the `etcd-operator`. On a **2-node cluster** this leaves node1 with zero
quorum peers, triggering the fatal panic.

Pacemaker STONITH does **not** trigger CEO member removal — only the taint does.

**This means**: the correct fencing sequence for TNF is:

```
pcs node fence <node>          ← hardware power-off via Redfish/IPMI
   ↓  (wait for fence to confirm)
out-of-service taint           ← now safe; node is physically off, CEO cannot react
```

**NEVER** apply `out-of-service` taints to a node that is still powered on.

See [ADR-011](../adrs/011-odf-tnf-demo5-fencing-procedure.md) for the full decision
record, and use [`scripts/odf-ha-fence-node.sh`](../../scripts/odf-ha-fence-node.sh)
which enforces this order automatically.

#### Recovery Procedure

If the panic has already occurred, follow these steps exactly:

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Step 1: Delete the stale etcd member data on node2 (the fenced node)
# This clears the invalid single-voter cluster state
ssh -i $SSH_KEY core@192.168.49.22 "sudo rm -rf /var/lib/etcd/member"

# Step 2: On node1, tell Pacemaker to start etcd with --force-new-cluster
# This flag makes etcd bootstrap a new single-member cluster using node1's WAL.
# The --lifetime reboot ensures the flag is cleared after the next reboot.
ssh -i $SSH_KEY core@192.168.49.21 \
  "sudo crm_attribute --lifetime reboot \
     --node openshift-node1 \
     --name force_new_cluster \
     --update openshift-node1"

# Step 3: Clear Pacemaker resource failures and let it restart etcd
ssh -i $SSH_KEY core@192.168.49.21 "sudo pcs resource cleanup etcd-clone"

# Step 4: Wait ~3 minutes for etcd to start with --force-new-cluster
# Monitor progress:
ssh -i $SSH_KEY core@192.168.49.21 "sudo pcs status"
# Expected: etcd-clone Started: [ openshift-node1 ]

# Step 5: Wait ~2 minutes for kube-apiserver to reconnect to the new etcd
# Once connected, the API returns without data loss:
oc get nodes
# Expected: openshift-node1 Ready
```

Total expected recovery time: **~5–7 minutes** from starting Step 2.

> For a fully scripted version, run:
> ```bash
> bash scripts/etcd-pacemaker-recovery.sh
> ```
> Full incident report: [`docs/hardening/etcd-removed-all-voters-v4.21-2026-06-08.md`](../hardening/etcd-removed-all-voters-v4.21-2026-06-08.md)

---

### 8.2 MDS Pod Scheduling Failure — ODF CephFilesystem Stuck

#### Symptom

After deploying the ODF `StorageCluster`, the CephFilesystem shows `Progressing`
indefinitely. The MDS pods remain in `Pending`:

```bash
oc get cephfilesystem -n openshift-storage
# NAME                         PHASE
# ocs-storagecluster-cephfs    Progressing

oc get pods -n openshift-storage | grep mds
# rook-ceph-mds-ocs-storagecluster-cephfs-a-*   0/1   Pending
```

#### Root Cause

On a resource-constrained KVM host, the MDS pods cannot be scheduled because there
is insufficient CPU or memory. The default ODF resource requests for MDS are too
high for a KVM dev environment with both control-plane nodes sharing one host.

#### Diagnosis

```bash
oc describe pod -n openshift-storage \
  $(oc get pods -n openshift-storage -o name | grep mds | head -1)
# Look for: Insufficient cpu / Insufficient memory in Events
```

#### Fix

Patch the MDS daemon resources in the `StorageCluster` spec:

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type=merge -p '{
    "spec": {
      "managedResources": {
        "cephFilesystems": {
          "reconcileStrategy": "ignore"
        }
      },
      "resources": {
        "mds": {
          "requests": {"cpu": "100m", "memory": "512Mi"},
          "limits":   {"cpu": "500m", "memory": "2Gi"}
        }
      }
    }
  }'
```

For a complete set of resource overrides for all ODF daemons on a constrained KVM
host, see [`examples/two-node-drbd/storagecluster-drbd.yaml`](../../examples/two-node-drbd/storagecluster-drbd.yaml)
and [ADR-009](../adrs/009-odf-tnf-post-install-tuning.md).

---

### 8.3 OSD Crash Loop After Fence — PG Inconsistency

#### Symptom

After a node fence-and-recover cycle, OSD pods restart in a crash loop and Ceph
reports `HEALTH_WARN` with placement group (PG) inconsistency:

```bash
oc exec -n openshift-storage rook-ceph-tools-* -- ceph status
# health: HEALTH_WARN
# 1 pgs inconsistent
# 2 scrub errors

oc get pods -n openshift-storage | grep osd
# rook-ceph-osd-0-*   CrashLoopBackOff
```

#### Cause

The fence interrupted an in-progress write, leaving a PG in an inconsistent state.
The OSD refuses to start until the inconsistency is repaired.

#### Fix

```bash
# 1. Identify the inconsistent PG
oc exec -n openshift-storage rook-ceph-tools-* -- ceph health detail
# Note the PG ID, e.g.: 2.1f

# 2. Run a deep scrub on the affected PG
oc exec -n openshift-storage rook-ceph-tools-* -- \
  ceph pg deep-scrub 2.1f

# 3. Wait for the scrub to complete (~2-5 min depending on PG size)
oc exec -n openshift-storage rook-ceph-tools-* -- \
  ceph status
# Wait until health: HEALTH_OK

# 4. If inconsistency persists after scrub, repair the PG:
oc exec -n openshift-storage rook-ceph-tools-* -- \
  ceph pg repair 2.1f
```

> **Note**: `ceph pg repair` should only be run after `deep-scrub` confirms the
> inconsistency. Running repair without deep-scrub first can mask data corruption.

---

### 8.4 OCS Operator Reverts Pool Size to `size=1`

#### Symptom

After setting pool replica count to 2, Ceph reports `HEALTH_WARN: pool has fewer
replicas than configured` and the OCS operator reverts the pool `size` back to 1.

#### Root Cause

The OCS operator manages pool size by default. On a 2-node cluster it considers
`size=2` as non-standard and reverts it.

#### Fix

Set `reconcileStrategy: ignore` on all managed resources so OCS stops managing
pool size:

```yaml
# In StorageCluster spec:
spec:
  managedResources:
    cephBlockPools:
      reconcileStrategy: ignore
    cephFilesystems:
      reconcileStrategy: ignore
    cephObjectStores:
      reconcileStrategy: ignore
```

Then explicitly apply `size=2` pool manifests from
[`examples/two-node-drbd/ceph-pools-size2.yaml`](../../examples/two-node-drbd/ceph-pools-size2.yaml).

See [ADR-008](../adrs/008-odf-tnf-pool-replica-strategy.md) for the full decision record.

---

### 8.5 `mon-c` Version Skew — CephFilesystem Stuck in Reconciling

#### Symptom

After deploying the floating monitor (`mon-c`) via `scripts/mon-deployment.sh`,
the CephFilesystem enters a `Reconciling` loop and never reaches `Ready`. The
rook-ceph operator logs show version mismatch errors.

#### Root Cause

The `mon-c` deployment uses a different Ceph container image SHA than `mon-a` and
`mon-b`. Even a minor version difference blocks CephFilesystem reconciliation
because Ceph's monitor election protocol rejects mixed-version quorums.

#### Fix

1. Get the exact image SHA used by the existing monitors:

```bash
oc get pod rook-ceph-mon-a-* -n openshift-storage \
  -o jsonpath='{.spec.containers[0].image}'
# Example: quay.io/ceph/ceph@sha256:abc123...
```

2. Update `scripts/mon-deployment.sh` (the `CEPH_IMAGE` variable) to match this
   exact SHA-pinned image reference.

3. Delete and redeploy `mon-c`:

```bash
oc delete deployment rook-ceph-mon-c -n openshift-storage
bash scripts/mon-deployment.sh
```

See [ADR-010](../adrs/010-odf-tnf-mon-c-downstream-image.md) for the full decision record.

---

## 9. cert-manager Issues

### 9.1 `CertificateRequest` Stuck in `Pending` or `Failed`

#### Symptom

```bash
oc get certificaterequest -n openshift-ingress
# NAME                         APPROVED   DENIED   READY   ISSUER                    REQUESTOR
# wildcard-apps-cert-xxxxx     True                False   letsencrypt-production    cert-manager
```

`oc describe certificaterequest <name> -n openshift-ingress` shows:

```
Message: Failed to create Order: ...
  Error: DNS provider credentials are invalid
```

or:

```
Message: Waiting on certificate issuance from order ...
  Reason: dns01 challenge pending
```

#### Diagnosis

```bash
# Check the Order object for the ACME DNS-01 challenge status
oc get order -n openshift-ingress
oc describe order -n openshift-ingress <order-name>

# Check the Challenge object
oc get challenge -n openshift-ingress
oc describe challenge -n openshift-ingress <challenge-name>

# Check cert-manager controller logs
# Note: cert-manager operands run in the cert-manager namespace (not openshift-cert-manager)
oc logs -n cert-manager \
  $(oc get pods -n cert-manager -l app=cert-manager -o name) \
  --tail=100
```

#### Fix — DNS provider secret misconfigured

The most common cause is a missing or incorrect DNS provider secret:

```bash
# Verify the secret exists in the cert-manager namespace
# (the operator creates this namespace; DNS secrets must go here, NOT openshift-cert-manager)
oc get secret -n cert-manager

# Verify the secret keys match what the ClusterIssuer references
oc describe secret route53-credentials -n cert-manager
# Keys must match the keyIDs in the ClusterIssuer spec.acme.solvers[].dns01.*SecretRef
```

If the secret is wrong, delete and recreate it, then delete the failing Order to trigger retry:

```bash
oc delete order -n openshift-ingress <order-name>
```

#### Fix — DNS TXT record not propagating

cert-manager waits for the DNS TXT record to propagate before notifying Let's Encrypt.
If your DNS provider has high TTLs or slow propagation:

```bash
# Check if the TXT record was created at the DNS provider
dig TXT _acme-challenge.apps.YOUR_CLUSTER.YOUR_DOMAIN

# If the TXT record exists but cert-manager still fails, check DNS resolver config
# cert-manager uses the cluster's DNS resolver; on TNF this may resolve internal DNS only
# Verify outbound DNS resolution from a cluster node:
oc debug node/<node-name> -- chroot /host \
  nslookup _acme-challenge.apps.YOUR_CLUSTER.YOUR_DOMAIN 8.8.8.8
```

---

### 9.2 Let's Encrypt Rate Limit Exceeded

#### Symptom

```bash
oc describe certificaterequest -n openshift-ingress <name>
# Message: Failed to finalize order: 429 urn:ietf:params:acme:error:rateLimited
#   Too many certificates already issued for exact set of domains
```

#### Cause

Let's Encrypt production has a limit of **5 duplicate certificates per week** per
registered domain. This is commonly hit when:
- Testing repeatedly without using the staging issuer first
- Deleting and re-creating certificates while debugging

#### Fix

Use the staging ClusterIssuer (`letsencrypt-staging`) for all testing. Staging has no
meaningful rate limits and issues certificates signed by "Fake LE Root X1" (not trusted
by browsers, but the issuance workflow is identical to production).

```bash
# Switch the Certificate to staging issuer
oc patch certificate wildcard-apps-cert \
  -n openshift-ingress \
  --type merge \
  -p '{"spec":{"issuerRef":{"name":"letsencrypt-staging"}}}'
```

Wait out the rate limit window (7 days from the first duplicate issuance) before switching
back to the production issuer.

---

### 9.3 cert-manager Pods Not Scheduling on TNF Control-Plane Nodes

#### Symptom

cert-manager pods remain `Pending` indefinitely:

```bash
# cert-manager operands run in the cert-manager namespace (created automatically by the operator)
oc get pods -n cert-manager
# NAME                                       READY   STATUS    RESTARTS   AGE
# cert-manager-controller-7b9f8c4d9-xxxxx   0/1     Pending   0          5m
```

```bash
oc describe pod -n cert-manager <pod-name>
# Events: ... 0/2 nodes are available: 2 node(s) had taint that the pod didn't tolerate
```

#### Diagnosis

TNF has no dedicated worker nodes — all workloads run on control-plane nodes that carry
the `node-role.kubernetes.io/master:NoSchedule` taint. cert-manager's upstream Helm chart
includes these tolerations by default, but the Red Hat operator may require the
`CertManager` CR to be patched.

#### Fix

```bash
# Check if cert-manager CR exists
oc get certmanager cluster

# Patch the CertManager CR to add control-plane tolerations
oc patch certmanager cluster \
  --type merge \
  -p '{
    "spec": {
      "controllerConfig": {
        "overrideArgs": []
      },
      "unsupportedConfigOverrides": {
        "controller": {
          "tolerations": [
            {
              "key": "node-role.kubernetes.io/master",
              "operator": "Exists",
              "effect": "NoSchedule"
            }
          ]
        },
        "webhook": {
          "tolerations": [
            {
              "key": "node-role.kubernetes.io/master",
              "operator": "Exists",
              "effect": "NoSchedule"
            }
          ]
        },
        "cainjector": {
          "tolerations": [
            {
              "key": "node-role.kubernetes.io/master",
              "operator": "Exists",
              "effect": "NoSchedule"
            }
          ]
        }
      }
    }
  }'
```

> **Note**: The Red Hat cert-manager-operator v1.x typically adds these tolerations
> automatically for OpenShift clusters. If pods still won't schedule, verify the
> `CertManager` CR status:
>
> ```bash
> oc describe certmanager cluster
> ```

---

### 9.4 cert-manager Unavailable After Node Fencing (TNF)

#### Symptom

After a STONITH fencing event on the node hosting cert-manager, certificate renewal
requests fail while cert-manager is rescheduling.

#### Behavior

This is expected on TNF. cert-manager runs as a single-replica `Deployment`. After node
fencing:

1. Pacemaker fences the failed node (~30 seconds)
2. Pacemaker recovers the cluster (etcd + API server return, ~60-90 seconds)
3. cert-manager pod reschedules on the surviving node (~30 seconds)

Total outage window: approximately 2-3 minutes.

#### Why This Is Acceptable

cert-manager renews certificates **30 days before expiry**. A 2-3 minute outage window
does not risk certificate expiry. Any ACME challenge interrupted mid-flight will be
automatically retried by cert-manager with exponential backoff when it comes back up.

#### Monitoring

```bash
# Check cert-manager pod status after fencing recovery
oc get pods -n cert-manager

# Check for any failed certificate renewals
oc get certificate -A
oc get certificaterequest -A

# Check cert-manager logs for retry activity
oc logs -n cert-manager \
  $(oc get pods -n cert-manager -l app=cert-manager -o name) \
  --tail=50
```
