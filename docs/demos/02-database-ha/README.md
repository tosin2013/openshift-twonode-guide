# Demo 2: Stateful Database HA — PostgreSQL on a Two-Node Cluster

**Objective**: Demonstrate that a stateful database workload survives both planned maintenance and unplanned node failure without data loss, validating the persistent storage layer of the two-node cluster.

---

## Prerequisites

- Completed [Demo 1](../01-fencing-validation/README.md) or a healthy two-node cluster
- `oc` CLI configured
- SSH key for bastion access to the cluster nodes

!!! important "Set environment variables first"
    Before running any commands, export these in your shell:

    ```bash
    export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
    export SSH_KEY=~/.ssh/openshift-twonode-ed25519
    ```

### Pre-flight: Verify Cluster Health

```bash
# Confirm both nodes are Ready
oc get nodes

# Confirm all cluster operators are healthy
oc get clusteroperators | grep -v "True.*False.*False"
# Expected: no output (all COs in Available=True, Progressing=False, Degraded=False)

# Confirm Pacemaker cluster is healthy
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status
# Expected: Online: [ openshift-node1 openshift-node2 ]
# etcd-clone Started: [ openshift-node1 openshift-node2 ]
# No Failed Resource Actions
```

If `Failed Resource Actions` appear:
```bash
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup
```

---

## Storage Architecture Note

> **Why not ODF/Ceph?**
>
> ODF with Ceph requires a minimum of 3 OSD nodes to maintain quorum. On a two-node cluster, Ceph cannot achieve quorum without a third node. This is a fundamental architectural constraint of Ceph, not a configuration issue.
>
> This demo intentionally uses **local block storage (Kubernetes `local` PV)** to reflect the recommended storage architecture for TNF clusters. A PVC backed by local storage is pinned to a specific node. On planned failover (node drain), the pod reschedules to the surviving node — but the PVC stays on the drained node, so the pod waits for the node to return.
>
> For zero-RPO storage across unplanned failures, see [Demo 5: DRBD Edge Storage](../05-drbd-edge-storage/README.md) (Developer Preview).

> **Note on LVM Operator (lvms-operator)**:
> The original demo referenced `lvms-operator` (TopoLVM). On this KVM development cluster the `lvms-operator` package is not available in the operator catalog (RC cluster). Instead, we use a manually provisioned Kubernetes `local` PV, which provides identical node-affinity-bound behavior. If you have `lvms-operator` installed, replace `local-storage` with your TopoLVM StorageClass name throughout this guide.

---

## Scenario

A PostgreSQL instance is deployed with a PVC backed by local storage on Node 1. A continuous write loop inserts rows into a test table. The demo covers:

- **Part A**: Planned maintenance — drain the non-PostgreSQL node → database unaffected
- **Part B**: Simulated hard failure — fence the non-PostgreSQL node → database survives

---

## Step 1: Provision Local Storage

Because `lvms-operator` may not be available in all environments, we use a manually provisioned Kubernetes `local` PV. This provides the same node-affinity behavior.

```bash
# Create the data directory on node1
ssh -i $SSH_KEY core@192.168.49.21 \
  "sudo mkdir -p /var/local-pvs/postgresql && sudo chmod 777 /var/local-pvs/postgresql"

# Create a local StorageClass and PV pinned to node1
oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgresql-local-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/local-pvs/postgresql
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - openshift-node1
EOF

# Verify
oc get storageclass && oc get pv
# Expected: local-storage StorageClass and postgresql-local-pv PV in Available state
```

---

## Step 2: Deploy PostgreSQL

```bash
# Create project with appropriate security policy for PostgreSQL
oc new-project database-ha-demo
oc label namespace database-ha-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline \
  --overwrite

oc apply -n database-ha-demo -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: database-ha-demo
type: Opaque
stringData:
  POSTGRESQL_USER: demo
  POSTGRESQL_PASSWORD: demo123
  POSTGRESQL_DATABASE: inventory
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: database-ha-demo
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
        - name: postgresql
          image: registry.redhat.io/rhel9/postgresql-15:latest
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgresql-secret
          volumeMounts:
            - name: data
              mountPath: /var/lib/pgsql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "demo", "-d", "inventory"]
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        storageClassName: local-storage
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: database-ha-demo
spec:
  selector:
    app: postgresql
  ports:
    - port: 5432
EOF

# Wait for PostgreSQL to be ready
oc -n database-ha-demo rollout status statefulset/postgresql

# Verify which node PostgreSQL is running on
oc -n database-ha-demo get pods -o wide
# Expected: postgresql-0 Running on openshift-node1 (or whichever node the local PV is on)
```

!!! note "Namespace PodSecurity policy"
    The `database-ha-demo` namespace must use `baseline` (not `restricted`) security policy.
    The Red Hat RHEL 9 PostgreSQL image runs as non-root but requires `baseline` for container
    privileges. The `oc label` command above configures this correctly.

---

## Step 3: Create the Test Schema and Start a Write Loop

```bash
# Create the test table
oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory -c "
  CREATE TABLE IF NOT EXISTS transactions (
    id SERIAL PRIMARY KEY,
    store_id INT NOT NULL,
    item TEXT NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
  );"
```

Start a background write loop as a Kubernetes **Job** (more reliable than `oc exec -it` for background operation):

```bash
oc -n database-ha-demo apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: write-loop
  namespace: database-ha-demo
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: writer
          image: registry.redhat.io/rhel9/postgresql-15:latest
          command:
            - bash
            - -c
            - |
              while true; do
                psql postgresql://demo:demo123@postgresql.database-ha-demo.svc.cluster.local/inventory -c "
                  INSERT INTO transactions (store_id, item, amount)
                  VALUES (
                    floor(random()*10+1)::int,
                    'item-' || floor(random()*100+1)::text,
                    (random()*100)::numeric(10,2)
                  );"
                sleep 1
              done
EOF
```

!!! tip "Write loop as a Job vs `oc exec -it`"
    The original README used `oc exec -it postgresql-0 -- bash -c "while true; ..."`.
    This requires an interactive terminal and breaks if the connection drops. A Kubernetes
    `Job` with `restartPolicy: OnFailure` is more robust — it survives brief API server
    interruptions and keeps writing through the failover events.

Verify writes are happening:
```bash
sleep 20
oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) AS rows_written FROM transactions;"
# Expected: ~20 rows after 20 seconds
```

---

## Step 4: Verify Pre-Failover Row Count

```bash
# Record current count before any failover test
PRE_COUNT=$(oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) FROM transactions;" -t | tr -d ' ')
echo "Pre-failover row count: ${PRE_COUNT}"
```

---

## Part A: Planned Maintenance (Node Drain)

```bash
# Identify which node PostgreSQL is NOT on (we will drain that one)
PG_NODE=$(oc -n database-ha-demo get pod postgresql-0 -o jsonpath='{.spec.nodeName}')
OTHER_NODE=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "${PG_NODE}")
echo "PostgreSQL is on: ${PG_NODE}"
echo "Draining: ${OTHER_NODE}"

# Drain the node that does NOT have PostgreSQL (simulates maintenance on that node)
# NOTE: --force is required for OpenShift control-plane guard pods
#       (etcd-guard, kube-apiserver-guard, etc.) which have no ReplicaSet controller
oc adm drain ${OTHER_NODE} --ignore-daemonsets --delete-emptydir-data --force

# PostgreSQL should remain running undisturbed (it was never on the drained node)
oc -n database-ha-demo get pods -o wide

# Check row count — writes should have continued uninterrupted
oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) FROM transactions;"

# Uncordon the drained node when ready
oc adm uncordon ${OTHER_NODE}
```

!!! warning "`--force` required for OpenShift drain"
    The standard `oc adm drain --ignore-daemonsets --delete-emptydir-data` will fail
    with:
    ```
    cannot delete Pods that declare no controller: openshift-etcd/etcd-guard-openshift-node2,
    openshift-kube-apiserver/kube-apiserver-guard-openshift-node2, ...
    ```
    These are OpenShift's control-plane "guard" pods — lightweight watchers that have no
    Deployment or ReplicaSet. They are safe to force-delete (the static pod controller
    recreates them automatically). Always add `--force` when draining OpenShift nodes.

### Drain Validation Result

| Check | Expected |
|---|---|
| PostgreSQL pod during drain | Unchanged — still Running on same node |
| Write loop | Continues without interruption |
| Row count | Monotonically increasing — no gaps |

---

## Part B: Hard Failure Simulation (Node Fencing)

```bash
# Fence the node PostgreSQL is NOT on (database survives directly)
PG_NODE=$(oc -n database-ha-demo get pod postgresql-0 -o jsonpath='{.spec.nodeName}')
OTHER_NODE=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "${PG_NODE}")
echo "Fencing: ${OTHER_NODE} (PostgreSQL is on ${PG_NODE})"

# Record pre-fence row count
PRE_FENCE=$(oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) FROM transactions;" -t | tr -d ' ')
echo "Pre-fence row count: ${PRE_FENCE}"

# Get the VM UUID for the node to fence (KVM environment)
VM_UUID=$(sudo virsh domuuid ${OTHER_NODE})
echo "VM UUID: ${VM_UUID}"

# Hard fence via Redfish (sushy-tools)
fence_redfish -a 192.168.122.10 --ssl-insecure -l admin -p admin \
  --systems-uri "/redfish/v1/Systems/${VM_UUID}" --ipport 8000 -o off
# Expected: "Success: Powered OFF"
```

!!! note "fence_redfish command differences from README original"
    Use `--systems-uri` instead of `-b`, `--ipport 8000`, and the correct sushy-tools
    address (`192.168.122.10`, not `localhost`). The password is `admin` not `changeme`.
    See [Demo 1](../01-fencing-validation/README.md) for full fencing validation context.

After fencing, the Kubernetes API may be **briefly unavailable** (~30–60 seconds). This is expected:
- Both nodes run `kube-apiserver` as a static pod
- HAProxy on the bastion must detect the failure and stop routing to the fenced node's API server
- The API recovers automatically once HAProxy health-checks propagate

Poll until the API recovers:
```bash
for i in $(seq 1 12); do
  RESULT=$(oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory \
    -c "SELECT COUNT(*) FROM transactions;" -t 2>/dev/null | tr -d ' ')
  if [[ -n "$RESULT" ]]; then
    echo "$(date +%H:%M:%S) — API up, rows: ${RESULT}"
    break
  fi
  echo "$(date +%H:%M:%S) — API recovering..."
  sleep 10
done
```

PostgreSQL itself **never stops**. The pod is on the surviving node (`openshift-node1`) and keeps accepting writes even when the Kubernetes API is briefly unreachable. The write-loop Job resumes automatically when the API comes back.

### Restore the Fenced Node

```bash
# Power the fenced node back on via Redfish
fence_redfish -a 192.168.122.10 --ssl-insecure -l admin -p admin \
  --systems-uri "/redfish/v1/Systems/${VM_UUID}" --ipport 8000 -o on

# Wait for node to rejoin
oc get nodes -w
# Wait until both nodes show Ready
```

!!! note "Node shows Ready before VM is actually up"
    The Kubernetes API may show the fenced node as `Ready` for up to 5 minutes after
    the VM is powered off. This is the Kubernetes node eviction timeout. Use
    `sudo virsh domstate <node>` on the KVM host to verify the actual VM power state.

---

## Step 5: Verify Zero Data Loss

```bash
# Stop the write loop
oc -n database-ha-demo delete job write-loop

# Final integrity check
oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory -c "
  SELECT
    COUNT(*) AS total_rows,
    MIN(created_at) AS first_write,
    MAX(created_at) AS last_write,
    MAX(id) - COUNT(*) AS missing_rows
  FROM transactions;"
# missing_rows should be 0 — no gaps in the ID sequence

# Verify data distribution (sanity check)
oc -n database-ha-demo exec postgresql-0 -- psql -U demo -d inventory -c "
  SELECT store_id, COUNT(*) FROM transactions GROUP BY store_id ORDER BY store_id;"
```

---

## Step 6: Post-Recovery Pacemaker Cleanup

After node2 rejoins, Pacemaker may log stale failed actions. Clean them up:

```bash
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup

# Wait ~30s and verify all resources are Started
sleep 30
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs status | grep -E "Started|Stopped|Failed"
# Expected: etcd-clone Started: [ openshift-node1 openshift-node2 ]
# No Failed Resource Actions
```

!!! note "etcd-clone Stopped on one node"
    As documented in Demo 1, the Pacemaker `etcd-clone` resource may show `Stopped` on
    one node after a failover cycle. The `pcs resource cleanup` above usually resolves it.
    If `Stopped` persists after 60 seconds:
    ```bash
    ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource restart etcd-clone
    ```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| PostgreSQL pod during non-PG-node drain | Unchanged — Running on same node |
| PostgreSQL pod during non-PG-node fence | Unchanged — Running on same node |
| Kubernetes API during fence | Brief interruption (~30–60s) — recovers automatically |
| `missing_rows` query | 0 — no data lost during drain or fence |
| Row count after drain | Higher than pre-drain — writes continued uninterrupted |
| Row count after fence | Higher than pre-fence — writes continued (API gap excluded) |
| Recovery time (node rejoin + all COs healthy) | ~5–10 minutes |

---

## Validated Results (2026-06-04)

Run against a KVM-based TNF cluster (OCP 4.22.0-rc.5) on IBM Cloud bare metal.

| Phase | Pre-count | Post-count | Missing rows | Result |
|---|---|---|---|---|
| Pre-test baseline | — | 37 rows | — | ✅ Write loop working |
| Part A: Drain `openshift-node2` | 37 | 165 | 0 | ✅ Zero interruption |
| Part B: Fence `openshift-node2` | 183 | 293 | 0 | ✅ Zero data loss |

**Observations:**
- PostgreSQL pod (`openshift-node1`) never restarted or moved throughout both tests
- Write loop (Kubernetes Job on `openshift-node1`) survived both events
- Kubernetes API was unavailable for ~30–60s after fencing — **the database itself was always available** and accepting writes; the write-loop Job resumed automatically
- Pacemaker `etcd-clone` stale failed actions after rejoining: resolved with `pcs resource cleanup`
- All cluster operators returned to healthy within ~5–7 minutes of node2 rejoining

---

## Cleanup

```bash
# Delete demo workloads
oc delete project database-ha-demo

# Delete the manual PV and StorageClass
oc delete pv postgresql-local-pv
oc delete storageclass local-storage

# Remove the data directory on node1
ssh -i $SSH_KEY core@192.168.49.21 "sudo rm -rf /var/local-pvs/postgresql"
```

---

## Why This Matters

Databases are the most common stateful workload at the edge — POS transaction logs, inventory records, telemetry. This demo proves that the two-node TNF architecture can safely host stateful database workloads with clear, documented HA behavior. The storage architecture note (ODF not suitable for two-node) is a critical education point for teams migrating from 3-node or larger clusters.
