#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MON_TEMPLATE="${SCRIPT_DIR}/../examples/two-node-drbd/mon-template.yaml"

export NAMESPACE=openshift-storage
# Production downstream Ceph image — matches what the ODF operator deploys for mon-a/mon-b.
# Using the dev image (quay.io/rhceph-ci) causes a version mismatch (20.1.0-159 vs 20.1.0-185)
# that blocks Rook from reconciling CephFilesystem. Always use the downstream image here.
# Source: https://access.redhat.com/articles/7139231
export CEPH_IMAGE=registry.redhat.io/rhceph/rhceph-9-rhel9@sha256:ad4a6277b33df016fb7444fc729b59a8ecc78cd689f9607ff80c553ec52285ad
export DRBD_UTILS_IMAGE=quay.io/rhceph-dev/odf4-drbd-rhel9:v4.21.0-1

# DRBD Configuration, match the names that were used during drbd configure.sh
export DRBD_RESOURCE_NAME="r0"
export DRBD_DEVICE="/dev/drbd0"

echo "Creating Service..."
kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: rook-ceph-mon
    app.kubernetes.io/component: cephclusters.ceph.rook.io
    app.kubernetes.io/created-by: rook-ceph-operator
    app.kubernetes.io/instance: c
    app.kubernetes.io/managed-by: rook-ceph-operator
    app.kubernetes.io/name: ceph-mon
    app.kubernetes.io/part-of: ocs-storagecluster-cephcluster
    ceph_daemon_id: c
    ceph_daemon_type: mon
    ceph.rook.io/do-not-reconcile: ""
    mon: c
    mon_cluster: ${NAMESPACE}
    mon_daemon: "true"
    rook.io/operator-namespace: ${NAMESPACE}
    rook_cluster: ${NAMESPACE}
  name: rook-ceph-mon-c
  namespace: ${NAMESPACE}
spec:
  internalTrafficPolicy: Cluster
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  ports:
    - name: tcp-msgr2
      port: 3300
      protocol: TCP
      targetPort: 3300
  selector:
    app: rook-ceph-mon
    ceph_daemon_id: c
    mon: c
    mon_cluster: ${NAMESPACE}
    rook_cluster: ${NAMESPACE}
  sessionAffinity: None
  type: ClusterIP
EOF

echo "Waiting for Service ClusterIP..."
while true; do
  CLUSTER_IP=$(kubectl get svc rook-ceph-mon-c -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
  if [[ -n "$CLUSTER_IP" && "$CLUSTER_IP" != "None" ]]; then
    break
  fi
  sleep 1
done

echo "ClusterIP found: $CLUSTER_IP"
export CLUSTER_IP="$CLUSTER_IP"

echo "Creating Deployment using ClusterIP..."
# Template lives in examples/two-node-drbd/mon-template.yaml — do not regenerate inline.
# The heredoc that previously lived here has been removed; edit the template file directly.

envsubst '${CLUSTER_IP} ${CEPH_IMAGE} ${NAMESPACE} ${DRBD_UTILS_IMAGE} ${DRBD_RESOURCE_NAME} ${DRBD_DEVICE}' \
  < "${MON_TEMPLATE}" > /tmp/mon.yaml
kubectl apply -n "$NAMESPACE" -f /tmp/mon.yaml

echo "Deployment completed"
