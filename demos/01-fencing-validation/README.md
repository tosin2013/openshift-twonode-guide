# Demo 1: Fencing Validation — The HA Chaos Test

**Objective**: Prove that the TNF cluster survives a hard, unplanned node failure and that Pacemaker fencing works correctly end-to-end.

This demo is the core proof-of-concept for the entire TNF architecture and directly replaces the node failure simulation in Module 3 of the retail-edge-ha-workshop (Steps 7 and 10).

---

## Prerequisites

- A deployed Two-Node OpenShift 4.22 TNF cluster (see [deployment guide](../../docs/deployment-guide.md))
- `oc` CLI configured with `KUBECONFIG` pointing to the cluster
- SSH access to both nodes (user `core`)
- `fence_redfish` installed on the bastion
- BMC access to both nodes (Redfish URL, credentials)

```bash
# Verify cluster readiness before starting
oc get nodes
# Both nodes must be Ready

oc get clusteroperators | grep -v "True.*False.*False"
# Must return nothing (all operators Available)

ssh core@192.168.150.21 sudo pcs status
# Both nodes Online, all resources Started
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
# Expected: one pod on node1, one pod on node2
```

## Step 2: Start a Continuous Availability Monitor

Open a second terminal and run this monitoring loop while the fencing test executes.

```bash
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
# Confirm which node has the Node 2 STONITH resource (it should be on Node 1)
ssh core@192.168.150.21 sudo pcs status

# Verify both etcd members are healthy
ssh core@192.168.150.21 sudo podman exec etcd etcdctl member list \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.key
# Expected: 2 members, both "started"
```

## Step 4: Hard-Power-Off Node 2 via BMC

This simulates an unplanned hardware failure — no graceful shutdown, no drain, no warning.

```bash
# Manual fencing test — powers off Node 2 via its BMC
# For KVM / sushy-tools:
NODE2_UUID=$(virsh domuuid openshift-node2)
fence_redfish \
  -a localhost \
  --ssl-insecure \
  -l admin \
  -p changeme \
  -b "/redfish/v1/Systems/${NODE2_UUID}" \
  -o off

# For bare metal:
# fence_redfish \
#   -a <node2-bmc-ip> \
#   -l <bmc-user> \
#   -p <bmc-password> \
#   -b "/redfish/v1/Systems/<system-id>" \
#   -o off

echo "Node 2 fenced. Watch the monitoring loop in your other terminal."
```

## Step 5: Observe the Failover Sequence

Over the next 30-60 seconds, observe:

### In the monitoring terminal:
- HTTP responses may briefly show timeouts (the pod on Node 2 is being terminated)
- HTTP 200 responses resume when the Pod from Node 2 reschedules to Node 1

### On Node 1:
```bash
ssh core@192.168.150.21

# Watch Pacemaker detect the failure and fence Node 2
sudo pcs status
# Node 2 will show: OFFLINE: [ node2 ]
# STONITH will show fence-node2 has completed

# Verify etcd transitioned to single-member mode
sudo podman exec etcd etcdctl member list \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.key
# Expected: 1 member (node1 only)

# Check Pacemaker fencing log
sudo journalctl -u pacemaker | grep -i "fence\|stonith" | tail -20
```

### In the OpenShift API:
```bash
# Watch Node 2 go NotReady and pods reschedule
oc get nodes -w &
oc -n fencing-demo get pods -o wide -w
```

## Step 6: Power Node 2 Back On and Observe Recovery

```bash
# Restore Node 2 power
# For KVM / sushy-tools:
fence_redfish \
  -a localhost \
  --ssl-insecure \
  -l admin \
  -p changeme \
  -b "/redfish/v1/Systems/${NODE2_UUID}" \
  -o on

# For bare metal:
# fence_redfish -a <node2-bmc-ip> -l <bmc-user> -p <bmc-password> \
#   -b "/redfish/v1/Systems/<system-id>" -o on
```

Wait approximately 5-10 minutes for Node 2 to boot and rejoin.

## Step 7: Validate Full Recovery

```bash
# Verify Node 2 is Ready
oc get nodes
# Both nodes should be Ready

# Verify all cluster operators recovered
oc get clusteroperators | grep -v "True.*False.*False"
# Must return nothing

# Verify etcd returned to 2-member cluster
ssh core@192.168.150.21 sudo podman exec etcd etcdctl member list \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:node1.key
# Expected: 2 members, both "started"

# Verify Pacemaker cluster is fully healthy
ssh core@192.168.150.21 sudo pcs status
# Both nodes Online, all resources Started

# Verify POS application is still serving requests
curl -s -o /dev/null -w "%{http_code}" \
  "http://$(oc -n fencing-demo get route pos-service -o jsonpath='{.spec.host}')"
# Expected: 200
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| POS application availability during outage | HTTP 200 within ~30s of Node 2 power-off (brief gap during pod reschedule is acceptable) |
| Pacemaker fencing event | `pcs status` shows `fence-node2` completed and Node 2 OFFLINE |
| etcd during outage | `etcdctl member list` shows 1 member (single-member cluster) |
| Node 2 recovery | Both nodes return to `Ready` in `oc get nodes` |
| etcd after recovery | `etcdctl member list` shows 2 members, both `started` |
| All cluster operators | `Available=True, Progressing=False, Degraded=False` |

---

## Cleanup

```bash
oc delete project fencing-demo
```

---

## Why This Matters

This demo directly proves the fundamental value proposition of TNF: a real, hardware-backed STONITH event — not a simulated or nested approximation — validates that:

1. The cluster survives an unplanned node failure without data loss.
2. Pacemaker's fencing mechanism works as designed with a real Redfish BMC (or sushy-tools).
3. etcd safely transitions between 2-member and 1-member states.
4. OpenShift application workloads reschedule and remain available with minimal interruption.
