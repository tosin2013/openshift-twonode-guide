# Demo 2: Stateful Database HA — PostgreSQL on a Two-Node Cluster

**Objective**: Demonstrate that a stateful database workload survives both planned maintenance and unplanned node failure without data loss, validating the persistent storage layer of the two-node cluster.

---

## Prerequisites

- Completed [Demo 1](../01-fencing-validation/README.md) or a healthy two-node cluster
- LVM Operator deployed and a `StorageClass` available (see [deployment guide](../../docs/deployment-guide.md#84-lvm-operator))
- `oc` CLI configured
- `psql` client on the bastion (or use `oc exec` into the PostgreSQL pod)

```bash
# Verify LVM StorageClass is available
oc get storageclass | grep lvms
# Expected: a StorageClass with PROVISIONER=topolvm.io

# Record the StorageClass name
SC_NAME=$(oc get storageclass -o jsonpath='{.items[?(@.provisioner=="topolvm.io")].metadata.name}')
echo "StorageClass: ${SC_NAME}"
```

---

## Storage Architecture Note

> **Why not ODF/Ceph?**
>
> ODF with Ceph requires a minimum of 3 OSD nodes to maintain quorum. On a two-node cluster, Ceph cannot achieve quorum without a third node. This is a fundamental architectural constraint of Ceph, not a configuration issue.
>
> This demo intentionally uses **local block storage (LVM/TopoLVM)** to reflect the recommended storage architecture for TNF clusters. A PVC backed by local storage is pinned to a specific node. On planned failover (node drain), the pod reschedules to the surviving node — but the PVC stays on the drained node, so the pod waits for the node to return.
>
> For zero-RPO storage across unplanned failures, see [Demo 5: DRBD Edge Storage](../05-drbd-edge-storage/README.md) (Developer Preview).

---

## Scenario

A PostgreSQL instance is deployed with a PVC backed by local storage on Node 1. A continuous write loop inserts rows into a test table. The demo covers:

- **Part A**: Planned maintenance — Node 2 drain → pod reschedules if needed
- **Part B**: Simulated hard failure — Node 2 fenced → database on Node 1 survives

---

## Step 1: Deploy PostgreSQL

```bash
oc new-project database-ha-demo

# Set the StorageClass name (adjust if yours is different)
SC_NAME=$(oc get storageclass -o jsonpath='{.items[?(@.provisioner=="topolvm.io")].metadata.name}')

oc apply -f - <<EOF
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
        storageClassName: ${SC_NAME}
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
```

## Step 2: Create the Test Schema and Start a Write Loop

```bash
# Create the test table
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory -c "
  CREATE TABLE IF NOT EXISTS transactions (
    id SERIAL PRIMARY KEY,
    store_id INT NOT NULL,
    item TEXT NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
  );"

# Start a background write loop (insert 1 row every second)
# Run in a second terminal and leave it running through the failover tests
oc -n database-ha-demo exec -it postgresql-0 -- bash -c "
  while true; do
    psql -U demo -d inventory -c \"
      INSERT INTO transactions (store_id, item, amount)
      VALUES (
        floor(random()*10+1)::int,
        'item-' || floor(random()*100+1)::text,
        (random()*100)::numeric(10,2)
      );\"
    sleep 1
  done"
```

## Step 3: Verify Pre-Failover Row Count

In a separate terminal:
```bash
# Check initial row count (run periodically during the demo)
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) AS total_rows FROM transactions;"
```

---

## Part A: Planned Maintenance (Node Drain)

```bash
# Identify which node the PostgreSQL pod is NOT on (we will drain that one)
PG_NODE=$(oc -n database-ha-demo get pod postgresql-0 -o jsonpath='{.spec.nodeName}')
OTHER_NODE=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "${PG_NODE}")
echo "PostgreSQL is on: ${PG_NODE}"
echo "Draining: ${OTHER_NODE}"

# Drain the node that does NOT have PostgreSQL (simulates maintenance on that node)
oc adm drain ${OTHER_NODE} --ignore-daemonsets --delete-emptydir-data

# Observe: other workloads reschedule to the remaining node
oc get pods -A -o wide | grep ${OTHER_NODE}

# PostgreSQL should remain running undisturbed (it was never on the drained node)
oc -n database-ha-demo get pods -o wide

# Check row count — writes should have continued uninterrupted
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*) FROM transactions;"

# Uncordon the drained node when ready
oc adm uncordon ${OTHER_NODE}
```

### Drain Validation Result

| Check | Expected |
|---|---|
| PostgreSQL pod during drain | Unchanged — still Running on same node |
| Write loop | Continues without interruption |
| Row count | Monotonically increasing — no gaps |

---

## Part B: Hard Failure Simulation (Node Fencing)

For maximum realism, fence the node that PostgreSQL is **not** on, then simulate the case where it **is** on the failed node.

```bash
# First: fence the node PostgreSQL is NOT on (database survives directly)
PG_NODE=$(oc -n database-ha-demo get pod postgresql-0 -o jsonpath='{.spec.nodeName}')
OTHER_NODE=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "${PG_NODE}")
echo "Fencing: ${OTHER_NODE} (PostgreSQL is on ${PG_NODE})"

# Get the UUID/address for the node to fence
# For KVM:
VM_UUID=$(virsh domuuid ${OTHER_NODE})
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o off

# Monitor: database continues to accept writes
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory \
  -c "SELECT COUNT(*), MAX(created_at) FROM transactions;"
```

### Restore the Fenced Node

```bash
# For KVM:
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${VM_UUID}" -o on

# Wait for node to rejoin
oc get nodes -w
# Wait until both nodes are Ready
```

---

## Step 4: Verify Zero Data Loss

```bash
# Stop the write loop (Ctrl+C in the write loop terminal)

# Final row count check
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory -c "
  SELECT
    COUNT(*) AS total_rows,
    MIN(created_at) AS first_write,
    MAX(created_at) AS last_write,
    MAX(id) - COUNT(*) AS missing_rows
  FROM transactions;"

# missing_rows should be 0 — no gaps in the sequence
# (small gaps are acceptable if the write loop was interrupted during pod reschedule)

# Verify data integrity
oc -n database-ha-demo exec -it postgresql-0 -- psql -U demo -d inventory -c "
  SELECT store_id, COUNT(*) FROM transactions GROUP BY store_id ORDER BY store_id;"
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| PostgreSQL during non-PG-node fence | Database continues without interruption |
| Data loss (drain scenario) | 0 rows lost |
| Data loss (fence scenario — database on surviving node) | 0 rows lost |
| Recovery time (node rejoin) | ~5-10 minutes for node to return to Ready |
| `missing_rows` query | 0 (or near-0 during brief pod reschedule gap) |

---

## Cleanup

```bash
oc delete project database-ha-demo
```

---

## Why This Matters

Databases are the most common stateful workload at the edge — POS transaction logs, inventory records, telemetry. This demo proves that the two-node TNF architecture can safely host stateful database workloads with clear, documented HA behavior. The storage architecture note (ODF not suitable for two-node) is a critical education point for teams migrating from 3-node or larger clusters.
