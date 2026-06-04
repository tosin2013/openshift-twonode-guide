# Two-Node OpenShift with ODF DRBD Storage

This example extends the `two-node-fencing` deployment with **ODF (OpenShift Data Foundation) using DRBD replication** — providing highly available block storage without a third quorum node.

## What's Different From two-node-fencing

The only infrastructure difference is that each KVM VM has an additional 100 GB disk (`/dev/vdb`) for ODF OSDs. The cluster configuration is otherwise identical.

## Deploy

```bash
# From the repo root — add ODF_DISK_SIZE=100 to create /dev/vdb on each node
ODF_DISK_SIZE=100 sudo bash scripts/deploy-tnf-kvm.sh
```

This creates:
- `twonode-openshift-node1.qcow2` — 130 GB OS disk
- `twonode-openshift-node1-odf.qcow2` — 100 GB ODF data disk (`/dev/vdb`)
- Same for node2

After deployment, follow the ODF DRBD installation steps below, or see [Demo 5](../../docs/demos/05-drbd-edge-storage/README.md).

## Post-Deployment: Verify ODF Disks

```bash
export SSH_KEY=~/.ssh/openshift-twonode-ed25519
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

for NODE_IP in 192.168.49.21 192.168.49.22; do
  echo "--- $NODE_IP ---"
  ssh -i $SSH_KEY -o StrictHostKeyChecking=no core@$NODE_IP lsblk
done
# Expected: vda (130G, OS) and vdb (100G, unpartitioned, for ODF)
```

## Install ODF Operator

```bash
oc apply -f odf-subscription.yaml
# Wait for operator ready
oc -n openshift-storage wait --for=condition=ready pod -l app=rook-ceph-operator \
  --timeout=600s
```

## Install StorageCluster (DRBD)

```bash
oc apply -f storagecluster-drbd.yaml
# Monitor progress
oc get storagecluster -n openshift-storage -w
```
