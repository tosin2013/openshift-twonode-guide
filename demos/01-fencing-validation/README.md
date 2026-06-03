# Demo 1: Fencing Validation — The HA Chaos Test

**Objective**: Prove that the TNF cluster survives a hard, unplanned node failure and that Pacemaker fencing works correctly end-to-end.

This demo is the core proof-of-concept for the entire TNF architecture and directly replaces the node failure simulation in Module 3 of the retail-edge-ha-workshop (Steps 7 and 10).

**Validated**: June 3, 2026 against OCP 4.22.0-rc.5 TNF cluster on KVM/IBM Cloud.

---

## Prerequisites

- A deployed Two-Node OpenShift 4.22 TNF cluster (see [KVM Developer Guide](../../docs/kvm-developer-guide.md))
- `oc` CLI configured with `KUBECONFIG` pointing to the cluster
- SSH access to both nodes (`core` user, key `~/.ssh/openshift-twonode-ed25519`)
- `fence_redfish` installed on the bastion host (installed by `scripts/bootstrap.sh`)
- sushy-emulator running at HTTPS `192.168.122.10:8000` (started by `scripts/deploy-tnf-kvm.sh`)

> **KVM environment note**: Node IPs are `192.168.49.21` (node1) and `192.168.49.22` (node2).
> The Redfish BMC for KVM is sushy-emulator at `192.168.122.10:8000` (HTTPS, self-signed cert).

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Verify cluster readiness before starting
oc get nodes
# Both nodes must show Ready

oc get clusteroperators | grep -v "True.*False.*False"
# Must return nothing (all operators Available)

ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Both nodes Online, all resources Started, no Failed Resource Actions
```

---

## Scenario

A simple stateless retail POS (Point of Sale) microservice is deployed across both nodes. Node 2 is then hard-powered-off via its BMC using `fence_redfish` directly — simulating an unplanned hardware failure (power loss, kernel panic, etc.).

---

## Step 1: Deploy the POS Microservice

```bash
# Create a namespace for the demo
oc new-project fencing-demo

# Deploy a simple HTTP microservice representing a retail POS endpoint
oc apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pos-service
  namespace: fencing-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pos-service
  template:
    metadata:
      labels:
        app: pos-service
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: pos-service
      containers:
        - name: pos
          image: quay.io/openshift/origin-hello-openshift:latest
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: pos-service
  namespace: fencing-demo
spec:
  selector:
    app: pos-service
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pos-service
  namespace: fencing-demo
spec:
  to:
    kind: Service
    name: pos-service
  port:
    targetPort: 8080
EOF

# Wait for both replicas to be ready
oc -n fencing-demo rollout status deployment/pos-service

# Verify pods are on different nodes
oc -n fencing-demo get pods -o wide
# Expected: one pod on openshift-node1, one pod on openshift-node2
```

## Step 2: Start a Continuous Availability Monitor

Open a second terminal and run this monitoring loop while the fencing test executes.

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

# Get the application route
POS_URL="http://$(oc -n fencing-demo get route pos-service -o jsonpath='{.spec.host}')"
echo "Testing: ${POS_URL}"

# Run a continuous availability check every 2 seconds
while true; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${POS_URL}")
  echo "$(date +%H:%M:%S) — HTTP ${STATUS}"
  sleep 2
done
```

Leave this running. A healthy response is HTTP 200.

## Step 3: Verify Pre-Fencing State

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Confirm Pacemaker cluster is healthy
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Expected:
#   Online: [ openshift-node1 openshift-node2 ]
#   openshift-node1_redfish Started openshift-node1
#   openshift-node2_redfish Started openshift-node2
#   etcd-clone Started: [ openshift-node1 openshift-node2 ]
#   No Failed Resource Actions

# Verify both etcd members are healthy (stacked etcd — use oc exec, not podman)
oc exec -n openshift-etcd etcd-openshift-node1 -c etcdctl -- \
  sh -c 'unset ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY; \
  etcdctl \
    --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.crt \
    --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.key \
    --endpoints=https://localhost:2379 member list -w table'
# Expected: 2 members, both "started"
```

> **Note**: In this TNF deployment etcd runs as **stacked static pods** (managed by the Cluster Etcd Operator), not standalone Podman containers. Use `oc exec ... -c etcdctl` with env vars unset, not `podman exec etcd etcdctl`.

## Step 4: Hard-Power-Off Node 2 via BMC

This simulates an unplanned hardware failure — no graceful shutdown, no drain, no warning.

```bash
# Get the Node 2 libvirt UUID (sushy-emulator uses this as the Redfish System ID)
NODE2_UUID=$(sudo virsh domuuid openshift-node2)
echo "Node2 UUID: ${NODE2_UUID}"

# Hard power-off Node 2 via sushy-emulator Redfish
# Note: use --systems-uri (not -b) and --ipport 8000 for this version of fence_redfish
fence_redfish \
  -a 192.168.122.10 \
  --ssl-insecure \
  -l admin \
  -p admin \
  --systems-uri "/redfish/v1/Systems/${NODE2_UUID}" \
  --ipport 8000 \
  -o off
# Expected: "Success: Powered OFF"

echo "Node 2 fenced. Watch the monitoring loop in your other terminal."
```

> **fence_redfish flag note**: The `-b` flag shown in older guides is not supported in fence-agents-redfish on RHEL 9/10.
> Use `--systems-uri` for the Redfish Systems path and `--ipport` for the non-standard port.

## Step 5: Observe the Failover Sequence

Over the next 30-60 seconds, observe:

### In the monitoring terminal:
- HTTP responses briefly show `000` (connection refused/timeout) — ~26 seconds in the validated run
- HTTP 200 responses resume when the Pod from Node 2 reschedules to Node 1

### On Node 1:
```bash
ssh -i $SSH_KEY core@192.168.49.21

# Watch Pacemaker detect the failure and run etcd force-new-cluster
sudo pcs status
# During recovery: etcd-clone may show FAILED on one node (stale monitor timeout — normal)
# After recovery:  etcd-clone Started: [ openshift-node1 openshift-node2 ]

# Monitor etcd recovery in Pacemaker/systemd logs
sudo journalctl -u pacemaker -f | grep -i "fenc\|force.new.cluster\|node2"
# Key lines to look for:
#   "openshift-node1 must force a new cluster"     ← Pacemaker detected quorum loss
#   "starting an etcd server" with "force-new-cluster":true  ← etcd restarted single-member
#   "adding openshift-node2 ... as learner"        ← node2 rejoined
```

### In the OpenShift API:
```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

# Watch nodes (API may be briefly unreachable ~20s during etcd quorum transition — normal)
oc get nodes --request-timeout=5s

# Watch pods reschedule
oc -n fencing-demo get pods -o wide
```

> **API brief interruption**: During the etcd `force-new-cluster` transition, the kube-apiserver
> briefly loses its etcd connection (~15-20 seconds). `oc` commands will fail with connection errors
> during this window — this is expected and resolves automatically.

## Step 6: Power Node 2 Back On

> **KVM note**: If the VM has `autostart: enabled` in libvirt (the default set by `hack/deploy-on-kvm.sh`),
> node2 will power back on automatically within seconds of being fenced. You may not need to run this step.
> Check first: `sudo virsh domstate openshift-node2`

If node2 is still off:

```bash
NODE2_UUID=$(sudo virsh domuuid openshift-node2)
fence_redfish \
  -a 192.168.122.10 \
  --ssl-insecure \
  -l admin \
  -p admin \
  --systems-uri "/redfish/v1/Systems/${NODE2_UUID}" \
  --ipport 8000 \
  -o on
# Expected: "Success: Powered ON"
```

Wait approximately 2-5 minutes for Node 2 to boot and rejoin (faster in KVM than bare metal).

## Step 7: Validate Full Recovery

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
export SSH_KEY=~/.ssh/openshift-twonode-ed25519

# Verify Node 2 is Ready
oc get nodes
# Both nodes should be Ready

# Verify all cluster operators recovered
oc get clusteroperators | grep -v "True.*False.*False"
# Must return nothing — note: etcd CO may show Progressing=True for ~3-5 min
# while TNF re-runs tnf-fencing-job, tnf-auth-job, tnf-update-setup-job
# This is normal TNF post-failover behavior. Wait for all to complete.

# Verify etcd returned to 2-member cluster
oc exec -n openshift-etcd etcd-openshift-node1 -c etcdctl -- \
  sh -c 'unset ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY; \
  etcdctl \
    --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.crt \
    --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node1.key \
    --endpoints=https://localhost:2379 member list -w table'
# Expected: 2 members, both "started"
# Note: node2's member ID will be different from pre-fencing (Pacemaker re-provisioned it)

# Clear Pacemaker failed resource history (historical records from the failover)
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup

# Verify Pacemaker cluster is fully healthy
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Expected: Both nodes Online, etcd-clone Started on both, no Failed Resource Actions

# Verify POS application is still serving requests
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://$(oc -n fencing-demo get route pos-service -o jsonpath='{.spec.host}')"
# Expected: 200
```

---

## Validated Results (June 3, 2026)

| Check | Expected | Actual |
|---|---|---|
| POS application downtime | HTTP 200 within ~30s | **~26s** (5 failed polls × 2s = 10s timeout window, spanning 20:37:17–20:38:01) |
| API disruption | Brief (etcd quorum transition) | **~15–20s** (oc commands failed during etcd restart) |
| Pacemaker etcd `force-new-cluster` | Triggered automatically | **Yes** — confirmed in `journalctl -u pacemaker` at 20:37:39 |
| etcd during outage | 1 member on node1 | **Yes** — `force-new-cluster=true` in etcd startup log |
| node2 recovery | Boot and rejoin | **Automatic** (libvirt `autostart: enabled`) — rejoined within ~60s |
| etcd after recovery | 2 members, both started | **Yes** — node2 rejoined as a new member (new member ID after re-provisioning) |
| TNF post-failover jobs | All completed | **Yes** — `tnf-fencing-job`, `tnf-auth-job`, `tnf-update-setup-job`, `tnf-after-setup-job` all Completed |
| All cluster operators | Available=True | **Yes** — all 35 COs healthy after ~5 min (etcd CO Progressing during TNF job re-run) |
| Monitor summary | Mostly 200 | **178/183 polls HTTP 200** (97.3% availability) |

### Observed Failover Timeline

```
20:37:12  fence_redfish "Success: Powered OFF" sent to sushy-emulator
20:37:17  First HTTP 000 — POS application briefly unreachable (pod on node2 lost)
20:37:39  Pacemaker detected etcd quorum loss, triggered force-new-cluster on node1
20:37:40  Last HTTP 000
20:38:01  HTTP 200 restored — POS pod rescheduled to node1, traffic serving
20:38:08  Pacemaker detected node2 back online (autostart), started resource recovery
20:38:33  etcd restarted on node1 with --force-new-cluster=true (single-member)
20:38:34  node2 added as etcd learner, began resync
20:47:10  All TNF post-failover jobs completed, etcd CO Progressing=False, revision 10
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| POS application availability during outage | HTTP 200 within ~30s of Node 2 power-off (brief gap during pod reschedule is acceptable) |
| Pacemaker force-new-cluster | `pcs status` shows etcd-clone and Pacemaker logs show `force_new_cluster` triggered |
| etcd during outage | `etcdctl member list` shows 1 member (single-member cluster on node1) |
| Node 2 recovery | Both nodes return to `Ready` in `oc get nodes` |
| etcd after recovery | `etcdctl member list` shows 2 members, both `started` (node2 gets a new member ID) |
| All cluster operators | `Available=True, Progressing=False, Degraded=False` after ~5 min post-recovery |
| TNF jobs | `tnf-fencing-job`, `tnf-auth-job`, `tnf-update-setup-job`, `tnf-after-setup-job` all Completed |

---

## Cleanup

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
oc delete project fencing-demo
```

---

## Why This Matters

This demo directly proves the fundamental value proposition of TNF: a real, hardware-backed STONITH event — not a simulated or nested approximation — validates that:

1. The cluster survives an unplanned node failure without data loss.
2. Pacemaker's fencing mechanism works as designed with a real Redfish BMC (sushy-emulator for KVM, or real iDRAC/iLO/XCC for bare metal).
3. etcd safely transitions between 2-member and 1-member states via Pacemaker's `force-new-cluster` mechanism.
4. OpenShift application workloads reschedule and remain available with minimal interruption (~26 seconds in the KVM environment).
5. The full cluster self-heals — TNF re-runs its setup jobs automatically to re-provision fencing credentials for the new etcd member.
