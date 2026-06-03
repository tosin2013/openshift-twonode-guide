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
