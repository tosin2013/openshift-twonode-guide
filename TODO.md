# TODO — openshift-twonode-guide

<!-- ADR-GENERATED-TASKS -->
<!-- This section is managed by `generate_adr_todo`. Tasks outside this
     bounded block are preserved verbatim across re-runs. -->
<!-- generated-at: 2026-06-02T20:25:34.784Z -->

## Summary

| ADR | Domain | Tasks | Status |
|-----|--------|-------|--------|
| [ADR-001](#adr-001-tnf-topology-selection) | Cluster Topology | 10 | pending |
| [ADR-002](#adr-002-agent-based-installer) | Deployment Automation | 8 | pending |
| [ADR-003](#adr-003-bmc--redfish-fencing-strategy) | Fencing / Hardware | 12 | pending |
| [ADR-004](#adr-004-etcd-outside-the-cluster) | Quorum Management | 10 | pending |
| [ADR-005](#adr-005-local-storage-over-odf) | Storage Architecture | 6 | pending |
| [ADR-006](#adr-006-ovnkubernetes-network-plugin) | Networking | 8 | pending |
| [ADR-007](#adr-007-kvm--sushy-tools-dev-environment) | Dev Environment | 16 | pending |
| **Total** | | **60** | |

> Each task is paired as **[TEST]** (validation/verification criteria) and **[PROD]** (implementation step).
> Linked ADR files live in [`docs/adrs/`](docs/adrs/).

---

## ADR-001: TNF Topology Selection

> **Source**: [`docs/adrs/001-tnf-topology-selection.md`](docs/adrs/001-tnf-topology-selection.md)
> **Domain**: cluster-topology / high-availability

### Phase 1 — Repository Scaffold and Architecture Documentation

- [ ] **[PROD]** Set `featureSet: TechPreviewNoUpgrade` in cluster configuration YAML
  <!-- task-id: 001-tnf-topology-selection-md/set-featureset-techpreviewnoupgrade-in-cluster-configuration-yaml/production -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _File: `examples/two-node-fencing/cluster.yml`_

- [ ] **[TEST]** Validate `featureSet: TechPreviewNoUpgrade` is present and correct in the cluster YAML template
  <!-- task-id: 001-tnf-topology-selection-md/set-featureset-techpreviewnoupgrade-in-cluster-configuration-yaml/test -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high
  _Lint the YAML against the `openshift-agent-install` schema; verify key is present._

- [ ] **[PROD]** Set `platform_type: baremetal`, `control_plane_replicas: 2`, `app_node_replicas: 0` in cluster configuration
  <!-- task-id: 001-tnf-topology-selection-md/set-platform-type-baremetal-control-plane-replicas-2-app-node-replicas-0/production -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _File: `examples/two-node-fencing/cluster.yml`_

- [ ] **[TEST]** Validate `platform_type`, `control_plane_replicas`, and `app_node_replicas` values in cluster YAML
  <!-- task-id: 001-tnf-topology-selection-md/set-platform-type-baremetal-control-plane-replicas-2-app-node-replicas-0/test -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Write TNF vs TNA architecture distinction in `docs/architecture.md` as the primary architectural decision
  <!-- task-id: 001-tnf-topology-selection-md/document-tnf-vs-tna-distinction-in-docs-architecture-md-as-the-primary-architect/production -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Include the topology comparison table (Total Nodes, Quorum Mechanism, etcd Management, GA Status, Upgrade Path)._

- [ ] **[TEST]** Review `docs/architecture.md` TNF/TNA section for accuracy against OCP 4.22 documentation
  <!-- task-id: 001-tnf-topology-selection-md/document-tnf-vs-tna-distinction-in-docs-architecture-md-as-the-primary-architect/test -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Create `examples/two-node-fencing/` directory with `cluster.yml` and `nodes.yml` as the canonical deployment templates
  <!-- task-id: 001-tnf-topology-selection-md/provide-examples-two-node-fencing-templates-as-the-canonical-deployment-path/production -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Validate `examples/two-node-fencing/` templates against `openshift-agent-install` `create-manifests.yml` schema
  <!-- task-id: 001-tnf-topology-selection-md/provide-examples-two-node-fencing-templates-as-the-canonical-deployment-path/test -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Add a TNA reference section in `docs/architecture.md` with a pointer to the future `examples/two-node-arbiter/` directory
  <!-- task-id: 001-tnf-topology-selection-md/reference-tna-as-a-future-enhancement-in-docs-architecture-md/production -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** low

- [ ] **[TEST]** Confirm TNA reference section correctly describes GA status and production readiness vs TNF Tech Preview status
  <!-- task-id: 001-tnf-topology-selection-md/reference-tna-as-a-future-enhancement-in-docs-architecture-md/test -->
  <!-- adr: 001-tnf-topology-selection.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** low

---

## ADR-002: Agent-Based Installer

> **Source**: [`docs/adrs/002-agent-based-installer.md`](docs/adrs/002-agent-based-installer.md)
> **Domain**: deployment-automation / installer-strategy

- [ ] **[PROD]** Add `tosin2013/openshift-agent-install` as upstream reference in `README.md` with role description
  <!-- task-id: 002-agent-based-installer-md/fork-or-reference-tosin2013-openshift-agent-install-in-the-repository-readme/production -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Verify README correctly describes the upstream tooling relationship and the `two-node-fencing` example's role
  <!-- task-id: 002-agent-based-installer-md/fork-or-reference-tosin2013-openshift-agent-install-in-the-repository-readme/test -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Create `examples/two-node-fencing/cluster.yml` with: `ocp_version: "4.22"`, `platform_type: baremetal`, `network_type: OVNKubernetes`, `control_plane_replicas: 2`, `app_node_replicas: 0`, and Redfish BMC address placeholders
  <!-- task-id: 002-agent-based-installer-md/create-examples-two-node-fencing-cluster-yml-with-tnf-specific-parameters/production -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Validate `cluster.yml` parses correctly with the `openshift-agent-install` `create-manifests.yml` playbook (dry-run)
  <!-- task-id: 002-agent-based-installer-md/create-examples-two-node-fencing-cluster-yml-with-tnf-specific-parameters/test -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Create `examples/two-node-fencing/nodes.yml` with per-node static MAC, IP, BMC address, and disk hints for 2 control-plane nodes
  <!-- task-id: 002-agent-based-installer-md/create-examples-two-node-fencing-nodes-yml-with-per-node-static-mac/production -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Validate `nodes.yml` static MAC fields are present and that the template cannot be used as-is without replacing placeholder values
  <!-- task-id: 002-agent-based-installer-md/create-examples-two-node-fencing-nodes-yml-with-per-node-static-mac/test -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document bastion host requirements and full ABI workflow (`create-manifests.yml` → ISO generation → boot → `wait-for install-complete`) in `docs/deployment-guide.md`
  <!-- task-id: 002-agent-based-installer-md/document-bastion-host-requirements-and-network-access-prerequisites/production -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Walkthrough the deployment guide end-to-end against a KVM environment to confirm steps are accurate and complete
  <!-- task-id: 002-agent-based-installer-md/document-bastion-host-requirements-and-network-access-prerequisites/test -->
  <!-- adr: 002-agent-based-installer.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

---

## ADR-003: BMC / Redfish Fencing Strategy

> **Source**: [`docs/adrs/003-bmc-redfish-fencing-strategy.md`](docs/adrs/003-bmc-redfish-fencing-strategy.md)
> **Domain**: high-availability / fencing / hardware-management

- [ ] **[PROD]** Write sushy-tools installation and configuration steps in `docs/deployment-guide.md` (KVM prerequisites section)
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-sushy-tools-installation-and-configuration-in-deployment-guide/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Include: pip install or container run command, sushy-emulator config file, systemd service unit._

- [ ] **[TEST]** Verify sushy-tools responds to a Redfish Systems query against a running KVM VM using the documented steps
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-sushy-tools-installation-and-configuration-in-deployment-guide/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high
  _`curl http://localhost:8000/redfish/v1/Systems` should return the two VM UUIDs._

- [ ] **[PROD]** Document `fence_redfish` STONITH resource creation commands for bare-metal and KVM environments in `docs/deployment-guide.md`
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-fence-redfish-stonith-resource-creation-commands/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Include `pcs stonith create` command with `pcmk_host_map`, `power_timeout`, `login_timeout` parameters._

- [ ] **[TEST]** Test `fence_redfish -o status` against both nodes in KVM environment using documented configuration
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-fence-redfish-stonith-resource-creation-commands/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Add BMC connectivity pre-flight checklist to `docs/deployment-guide.md` (reachability test, credential validation)
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/include-bmc-connectivity-validation-steps-in-pre-deployment-checklist/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Confirm pre-flight checklist catches an unreachable BMC before cluster deployment begins
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/include-bmc-connectivity-validation-steps-in-pre-deployment-checklist/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Create `demos/01-fencing-validation/` with manual `fence_redfish` test script followed by Pacemaker-triggered automated fencing test
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/in-demos-01-fencing-validation-include-manual-fence-redfish-test/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Scenario: deploy POS microservice → hard-power-off Node 2 via `fence_redfish` → observe Pacemaker STONITH → confirm app stays up → power Node 2 on → observe rejoin._

- [ ] **[TEST]** Execute full fencing validation demo end-to-end; confirm POS app remains reachable during node outage and all operators return `Available=True` after recovery
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/in-demos-01-fencing-validation-include-manual-fence-redfish-test/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Add fencing timeout tuning parameters to `docs/troubleshooting.md` (real BMC vs sushy-tools latency differences)
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-fencing-timeout-tuning-parameters-in-troubleshooting-guide/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Verify troubleshooting guide covers fencing agent misconfiguration failure mode as specified in PRD Section 5.1
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/document-fencing-timeout-tuning-parameters-in-troubleshooting-guide/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Write `demos/02-database-ha/` PostgreSQL HA scenario with drain and hard-failure simulation
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/write-demos-02-database-ha-postgresql-scenario/production -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Deploy PostgreSQL StatefulSet → run continuous write loop → drain Node 2 → verify pod reschedules → verify zero data loss → simulate hard failure → verify auto-recovery._

- [ ] **[TEST]** Verify no data loss after drain-and-reschedule; verify automatic recovery after hard fencing in Demo 2
  <!-- task-id: 003-bmc-redfish-fencing-strategy-md/write-demos-02-database-ha-postgresql-scenario/test -->
  <!-- adr: 003-bmc-redfish-fencing-strategy.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

---

## ADR-004: etcd Outside the Cluster

> **Source**: [`docs/adrs/004-etcd-outside-cluster.md`](docs/adrs/004-etcd-outside-cluster.md)
> **Domain**: cluster-data-plane / quorum-management

- [ ] **[PROD]** Write Pacemaker + etcd architecture section in `docs/architecture.md` including a diagram showing Pacemaker → STONITH → etcd-in-Podman → OpenShift API server relationship
  <!-- task-id: 004-etcd-outside-cluster-md/document-pacemaker-etcd-architecture-in-docs-architecture-md/production -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Review architecture diagram for correctness — confirm etcd-outside-cluster model is not confused with standard CEO-managed etcd
  <!-- task-id: 004-etcd-outside-cluster-md/document-pacemaker-etcd-architecture-in-docs-architecture-md/test -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Reference `two-node-toolbox` Pacemaker resource configuration commands in `docs/deployment-guide.md` (post-install Pacemaker setup section)
  <!-- task-id: 004-etcd-outside-cluster-md/reference-two-node-toolbox-for-pacemaker-resource-configuration/production -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Verify that `two-node-toolbox` reference links and commands are current for OCP 4.22
  <!-- task-id: 004-etcd-outside-cluster-md/reference-two-node-toolbox-for-pacemaker-resource-configuration/test -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document the full set of health validation commands in `docs/deployment-guide.md` post-install section: `pcs status`, `podman ps`, `etcdctl endpoint health`, `oc get clusteroperators`
  <!-- task-id: 004-etcd-outside-cluster-md/document-health-validation-commands-pcs-status-podman-ps-etcdctl/production -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Run each validation command against a deployed KVM cluster; confirm expected output is documented accurately
  <!-- task-id: 004-etcd-outside-cluster-md/document-health-validation-commands-pcs-status-podman-ps-etcdctl/test -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Include etcd member count transition (2 → 1 → 2) observation in `demos/01-fencing-validation/` validation steps
  <!-- task-id: 004-etcd-outside-cluster-md/include-etcd-health-validation-in-demo-1-fencing-validation/production -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Use `etcdctl member list` to confirm transition from 2-member to 1-member cluster and back._

- [ ] **[TEST]** Confirm Demo 1 validation steps capture the etcd single-member-cluster state during node outage
  <!-- task-id: 004-etcd-outside-cluster-md/include-etcd-health-validation-in-demo-1-fencing-validation/test -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Write dedicated etcd troubleshooting section in `docs/troubleshooting.md`: etcd failing to form quorum, Pacemaker etcd resource failing to start, STONITH failure leaving cluster frozen
  <!-- task-id: 004-etcd-outside-cluster-md/add-etcd-troubleshooting-section-in-docs-troubleshooting-md/production -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Verify troubleshooting guide covers all three etcd failure modes specified in PRD Section 5.1 (quorum failure, Pacemaker resource failure, STONITH failure)
  <!-- task-id: 004-etcd-outside-cluster-md/add-etcd-troubleshooting-section-in-docs-troubleshooting-md/test -->
  <!-- adr: 004-etcd-outside-cluster.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

---

## ADR-005: Local Storage over ODF

> **Source**: [`docs/adrs/005-local-storage-over-odf-ceph.md`](docs/adrs/005-local-storage-over-odf-ceph.md)
> **Domain**: storage-architecture / persistent-volumes

- [ ] **[PROD]** Add LVM Operator deployment steps to `docs/deployment-guide.md` post-install validation section
  <!-- task-id: 005-local-storage-over-odf-ceph-md/deploy-lvm-operator-in-deployment-guide/production -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Verify LVM Operator deploys successfully and creates a usable `StorageClass` on the two-node KVM cluster
  <!-- task-id: 005-local-storage-over-odf-ceph-md/deploy-lvm-operator-in-deployment-guide/test -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Write `demos/02-database-ha/` with LVM-backed PostgreSQL `StatefulSet` and a "Storage Architecture Note" explaining why ODF is not used
  <!-- task-id: 005-local-storage-over-odf-ceph-md/write-demos-02-database-ha-using-lvm-operator-storage-class/production -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Confirm `demos/02-database-ha/README.md` clearly explains local storage data-loss risk on hard failure without replication
  <!-- task-id: 005-local-storage-over-odf-ceph-md/write-demos-02-database-ha-using-lvm-operator-storage-class/test -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Write `demos/05-drbd-edge-storage/` following the Red Hat Developer Preview guide with a prominent "Developer Preview Warning" listing unsupported features (NooBaa, NFS, RGW, Regional DR)
  <!-- task-id: 005-local-storage-over-odf-ceph-md/write-demos-05-drbd-edge-storage-with-developer-preview-warning/production -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium
  _Validate: `drbdadm status` shows UpToDate on both nodes; write test file to PVC; fence Node 2; confirm PVC accessible on Node 1; verify data integrity._

- [ ] **[TEST]** Verify Demo 5 README explicitly lists all Developer Preview limitations and matches the Red Hat ODF 4.21 Developer Preview documentation
  <!-- task-id: 005-local-storage-over-odf-ceph-md/write-demos-05-drbd-edge-storage-with-developer-preview-warning/test -->
  <!-- adr: 005-local-storage-over-odf-ceph.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

---

## ADR-006: OVNKubernetes Network Plugin

> **Source**: [`docs/adrs/006-ovnkubernetes-network-plugin.md`](docs/adrs/006-ovnkubernetes-network-plugin.md)
> **Domain**: network-architecture / cni-plugin

- [ ] **[PROD]** Set `network_type: OVNKubernetes` in `examples/two-node-fencing/cluster.yml`
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/set-network-type-ovnkubernetes-in-cluster-yml/production -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Validate `network_type: OVNKubernetes` is set; confirm OpenShiftSDN is not present anywhere in the templates
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/set-network-type-ovnkubernetes-in-cluster-yml/test -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document OVNKubernetes requirement and rationale (TNF hard requirement + SDN deprecation) in `docs/architecture.md`
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/document-ovnkubernetes-requirement-in-docs-architecture-md/production -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Confirm architecture doc explains both the TNF-specific requirement and the OpenShiftSDN deprecation context
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/document-ovnkubernetes-requirement-in-docs-architecture-md/test -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Add OVNKubernetes-specific network validation commands to `docs/deployment-guide.md` post-install section (`oc get network.operator`, pod connectivity tests)
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/include-ovnkubernetes-network-validation-steps-in-deployment-guide/production -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Run documented OVNKubernetes validation commands against deployed KVM cluster; confirm expected output matches
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/include-ovnkubernetes-network-validation-steps-in-deployment-guide/test -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Add OVNKubernetes MTU troubleshooting notes for KVM environments to `docs/troubleshooting.md`
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/add-ovnkubernetes-mtu-troubleshooting-notes-for-kvm/production -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Verify troubleshooting section covers MTU mismatch symptoms and remediation for libvirt bridge configurations
  <!-- task-id: 006-ovnkubernetes-network-plugin-md/add-ovnkubernetes-mtu-troubleshooting-notes-for-kvm/test -->
  <!-- adr: 006-ovnkubernetes-network-plugin.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

---

## ADR-007: KVM + sushy-tools Dev Environment

> **Source**: [`docs/adrs/007-kvm-sushy-tools-dev-environment.md`](docs/adrs/007-kvm-sushy-tools-dev-environment.md)
> **Domain**: development-environment / testing-infrastructure

- [ ] **[PROD]** Document KVM host prerequisites in `docs/deployment-guide.md`: CPU virtualization (VT-x/AMD-V), minimum RAM (32 GB recommended), disk space; include `lsblk` and `free -h` commands
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-kvm-host-prerequisites-in-deployment-guide/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Run `lsblk` and `free -h` on the development host; confirm prerequisite check commands return the required minimum values
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-kvm-host-prerequisites-in-deployment-guide/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document `icm --help` usage for memory management verification in `docs/deployment-guide.md` prerequisites section
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-icm-usage-for-memory-verification/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Verify `icm` CLI is available and `icm --help` output matches the documented usage in the deployment guide
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-icm-usage-for-memory-verification/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Write sushy-tools installation section: pip install or container pull, `sushy-emulator` config file, start command, service verification
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/provide-sushy-tools-installation-commands-and-config/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Install sushy-tools on the development host using documented steps; confirm `sushy-emulator` starts and responds on port 8000
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/provide-sushy-tools-installation-commands-and-config/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document libvirt VM creation with static MAC addresses for both control-plane nodes (virsh commands + XML snippet)
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-libvirt-vm-creation-with-static-mac-addresses/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high
  _Static MACs are the critical fix for the original Module 3 MAC-regeneration failure._

- [ ] **[TEST]** Confirm VMs created with documented commands retain the same MAC address across power cycles (`virsh domiflist`)
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-libvirt-vm-creation-with-static-mac-addresses/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document the sushy-tools → libvirt VM UUID mapping procedure: `virsh list --all`, `virsh domuuid <name>`, constructing the Redfish System URL
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/provide-sushy-tools-libvirt-vm-uuid-mapping-procedure/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Verify the documented UUID mapping procedure produces a valid Redfish System URL that responds to `GET /redfish/v1/Systems/<uuid>`
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/provide-sushy-tools-libvirt-vm-uuid-mapping-procedure/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Document how to construct the `bmc.address` Redfish URL for `nodes.yml`: `redfish-virtualmedia://localhost:8000/redfish/v1/Systems/<uuid>`
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-bmc-address-redfish-url-construction-for-nodes-yml/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Confirm `bmc.address` format in `nodes.yml` example resolves correctly when used with `fence_redfish -a <address> -o status`
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/document-bmc-address-redfish-url-construction-for-nodes-yml/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** high

- [ ] **[PROD]** Create a "KVM vs Bare Metal" comparison table in `docs/deployment-guide.md` showing which steps differ between the two environments
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/include-kvm-vs-bare-metal-comparison-table-in-deployment-guide/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Verify comparison table covers all meaningful differences: BMC type, static MAC source, network bridge config, ISO delivery method, bastion network access
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/include-kvm-vs-bare-metal-comparison-table-in-deployment-guide/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Write `demos/03-openshift-virtualization/` for legacy VM HA (RHEL VM import via CDI, fence Node 2, confirm VM restarts on Node 1 via `RunStrategy: Always`)
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/write-demos-03-openshift-virtualization-legacy-vm-ha/production -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: production -->
  **Status:** pending | **Priority:** medium

- [ ] **[TEST]** Execute Demo 3 end-to-end; confirm VM restarts on surviving node and application state is consistent after recovery
  <!-- task-id: 007-kvm-sushy-tools-dev-environment-md/write-demos-03-openshift-virtualization-legacy-vm-ha/test -->
  <!-- adr: 007-kvm-sushy-tools-dev-environment.md --><!-- tdd: test -->
  **Status:** pending | **Priority:** medium

---

## Additional Tasks (PRD Phase 2 — Demos)

> These tasks arise directly from PRD Section 5.2 and are not fully covered by ADR implementation plans.

- [ ] **[PROD]** Write `demos/04-edge-ai-inference/` — deploy YOLOv8-style inference container, send test retail images, validate predictions, confirm service survives node failure
  <!-- task-id: prd-demo-04-edge-ai-inference/production -->
  **Status:** pending | **Priority:** medium
  _Use a standard `Deployment` object; reference OpenShift AI-compatible model packaging._

- [ ] **[TEST]** Send batch of test images to inference endpoint; verify prediction responses and service availability during fencing event (reuse Demo 1 fencing scenario)
  <!-- task-id: prd-demo-04-edge-ai-inference/test -->
  **Status:** pending | **Priority:** medium

- [ ] **[PROD]** Create repository `README.md` with: project overview, TNF/TNA decision summary, quick-start link to `docs/deployment-guide.md`, links to all 5 demo directories, upstream references
  <!-- task-id: prd-readme/production -->
  **Status:** pending | **Priority:** high

- [ ] **[TEST]** Confirm README satisfies PRD Section 7 Success Criterion: "a user following the deployment guide can stand up the cluster without referencing external documentation"
  <!-- task-id: prd-readme/test -->
  **Status:** pending | **Priority:** high

---

## Future Enhancements (Non-Blocking)

> From PRD Section 8. Not required for initial release.

- [ ] GitHub Actions CI — YAML lint for `examples/` templates against `openshift-agent-install` schema on every PR
- [ ] Disconnected / Air-Gap Support — templates and docs for TNF deployment without internet access using a local mirror registry
- [ ] RHACM Integration — `rhacm/` directory with `ClusterDeployment` and `AgentClusterInstall` manifests (when TNF via RHACM is stable)
- [ ] TNA Variant — `examples/two-node-arbiter/` directory for GA-supported TNA topology
- [ ] Ansible Automation Platform (AAP) Workflow — convert demo scripts to Ansible playbooks runnable from AAP on KVM

<!-- /ADR-GENERATED-TASKS -->
