# Demos

This section contains hands-on demonstrations that validate the HA capabilities of a deployed Two-Node OpenShift TNF cluster. Each demo targets a specific edge workload pattern and is designed to be run against a live cluster.

!!! tip "Run in order"
    Demo 1 proves the cluster's HA foundation. Later demos build on that foundation, so completing them in order is recommended — though each is independently executable.

## Demo Status

| Demo | Scenario | Status |
|---|---|---|
| [01 Fencing Validation](01-fencing-validation/README.md) | Hard node failure + Pacemaker STONITH | Validated — June 3, 2026 |
| [02 Database HA](02-database-ha/README.md) | PostgreSQL StatefulSet through planned/unplanned failure | Stub — not yet validated |
| [03 OpenShift Virtualization](03-openshift-virtualization/README.md) | Legacy VM HA alongside containers | Stub — not yet validated |
| [04 Edge AI Inference](04-edge-ai-inference/README.md) | YOLOv8-style object detection at the edge | Stub — not yet validated |
| [05 DRBD Edge Storage](05-drbd-edge-storage/README.md) | Replicated block storage via ODF + DRBD | Stub — Developer Preview |

## Prerequisites for All Demos

- A deployed and healthy Two-Node OpenShift 4.22 TNF cluster
- `oc` CLI configured with a valid `KUBECONFIG`
- SSH access to both nodes using the `core` user
- All 35 cluster operators `Available` (`oc get co` shows no degraded operators)

See [KVM Developer Guide](../kvm-developer-guide.md) for cluster deployment instructions.

## What "Validated" Means

A demo is marked **Validated** when it has been run end-to-end against a live cluster, all expected outcomes have been observed, and the README has been updated with actual command output and timing data. Stubs contain the planned scenario and skeleton steps but have not yet been executed.
