# Two-Node with Arbiter (TNA) — Placeholder

> **Status**: Not yet implemented. This directory is a stub for a future TNA
> deployment example. See below for when to choose TNA over TNF.

---

## What Is TNA?

**Two-Node with Arbiter (TNA)** is a GA-supported OpenShift topology introduced in
OCP 4.20. It uses three nodes: two full control-plane nodes plus one lightweight
arbiter node that only participates in etcd quorum (it runs no workloads).

```
Node 1 (full)  ←→  Node 2 (full)
        ↑                ↑
        └──── Arbiter ───┘
              (quorum only)
```

Because there are three etcd members, TNA uses the **standard Cluster Etcd Operator**
— no Pacemaker, no STONITH, no external etcd management required.

---

## TNF vs TNA — When to Choose Each

| Decision Factor | TNF (this repo) | TNA |
|----------------|-----------------|-----|
| Physical nodes available | Exactly 2 | 3 (arbiter can be small VM) |
| GA support | Technology Preview only | ✅ Generally Available |
| Upgrade path | Reinstall only | Standard OCP upgrade |
| Pacemaker expertise required | Yes | No |
| BMC / Redfish hardware required | Yes | No |
| Storage options | LVM Operator, ODF+DRBD | Standard ODF, LVM |
| Best for | Remote sites with hard 2-server limit | Retail, manufacturing at scale |

**Choose TNA if**:
- You can place a small VM (4 vCPU, 8 GB RAM) as an arbiter anywhere in the network
- You need the standard OCP upgrade lifecycle
- You prefer a simpler operational model without Pacemaker

**Choose TNF (this repository) if**:
- You have exactly 2 physical servers and cannot add a third node
- You accept the Technology Preview constraints
- Your hardware has Redfish-capable BMCs

---

## Official Documentation

- [Two-Node OpenShift with Arbiter — OpenShift Docs](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/installing-with-agent-based-installer.html)
- [Two-Node with Arbiter Architecture Overview](https://docs.openshift.com/container-platform/latest/architecture/architecture-installation.html)

---

## Future Implementation Plan

A full TNA example in this repository would include:

```
examples/two-node-arbiter/
├── cluster.yml          # ABI config: platform_type: baremetal, control_plane_replicas: 3 (2 full + 1 arbiter)
├── nodes.yml            # Node definitions: 2 full nodes + 1 arbiter node
└── README.md            # This file + deployment walkthrough
```

The key difference from TNF's `cluster.yml` is:
- `control_plane_replicas: 3` (not 2)
- No `featureSet: TechPreviewNoUpgrade`
- No Pacemaker post-install steps
- Standard etcd health validation (not `pcs status`)

To contribute a TNA example, see [CONTRIBUTING.md](../../CONTRIBUTING.md).
