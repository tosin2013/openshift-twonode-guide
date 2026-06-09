#!/bin/bash
# Post-installation tuning for ODF on Two-Node OpenShift (TNF)
#
# Source: https://access.redhat.com/articles/7139231
# "Deploying ODF on a Two-Node OpenShift Cluster with Fencing and DRBD"
# ODF 4.21 Developer Preview
#
# Purpose: Reduce CSI driver resource requests so they fit within the tight
#          CPU budget of a 2-node, 8-vCPU cluster. Patches the driver CRs
#          (openshift-storage.rbd.csi.ceph.com and cephfs equivalent),
#          which the CSI Addons operator propagates to all controller/node
#          plugin deployments.
#
# Run from a shell with oc/kubectl access to the cluster:
#   bash update-csi-resources.sh

set -eu

RBD_DRIVER_NAME="openshift-storage.rbd.csi.ceph.com"
CEPHFS_DRIVER_NAME="openshift-storage.cephfs.csi.ceph.com"

NAMESPACE="openshift-storage"

echo "Patching RBD CSI driver resources..."
kubectl patch driver "${RBD_DRIVER_NAME}" \
  -n "${NAMESPACE}" \
  --type=merge \
  -p '
spec:
  controllerPlugin:
    resources:
      addons:
        requests:
          cpu: 50m
          memory: 50Mi
      attacher:
        requests:
          cpu: 25m
          memory: 50Mi
      logRotator:
        requests:
          cpu: 10m
          memory: 32Mi
      omapGenerator:
        requests:
          cpu: 25m
          memory: 50Mi
      plugin:
        requests:
          cpu: 100m
          memory: 100Mi
      provisioner:
        requests:
          cpu: 25m
          memory: 50Mi
      resizer:
        requests:
          cpu: 25m
          memory: 50Mi
      snapshotter:
        requests:
          cpu: 25m
          memory: 50Mi
  nodePlugin:
    resources:
      addons:
        requests:
          cpu: 50m
          memory: 50Mi
      registrar:
        requests:
          cpu: 10m
          memory: 10Mi
      logRotator:
        requests:
          cpu: 10m
          memory: 32Mi
      plugin:
        requests:
          cpu: 50m
          memory: 100Mi
'

echo "Patching CephFS CSI driver resources..."
kubectl patch driver "${CEPHFS_DRIVER_NAME}" \
  -n "${NAMESPACE}" \
  --type=merge \
  -p '
spec:
  controllerPlugin:
    resources:
      addons:
        requests:
          cpu: 50m
          memory: 50Mi
      attacher:
        requests:
          cpu: 25m
          memory: 50Mi
      logRotator:
        requests:
          cpu: 10m
          memory: 32Mi
      omapGenerator:
        requests:
          cpu: 25m
          memory: 50Mi
      plugin:
        requests:
          cpu: 100m
          memory: 100Mi
      provisioner:
        requests:
          cpu: 25m
          memory: 50Mi
      resizer:
        requests:
          cpu: 25m
          memory: 50Mi
      snapshotter:
        requests:
          cpu: 25m
          memory: 50Mi
  nodePlugin:
    resources:
      addons:
        requests:
          cpu: 50m
          memory: 50Mi
      registrar:
        requests:
          cpu: 10m
          memory: 10Mi
      logRotator:
        requests:
          cpu: 10m
          memory: 32Mi
      plugin:
        requests:
          cpu: 50m
          memory: 100Mi
'

echo "Patch applied successfully"
