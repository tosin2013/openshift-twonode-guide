# Deployment Guide — Two-Node OpenShift 4.22 with Fencing (TNF)

This guide walks through every step needed to deploy a Two-Node OpenShift 4.22 cluster using the Agent-Based Installer (ABI) via the `openshift-agent-install` framework. It covers both **KVM development** and **bare-metal production** environments.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [KVM Environment Setup](#2-kvm-environment-setup)
3. [Bare Metal Environment Setup](#3-bare-metal-environment-setup)
4. [Configuring the Cluster Templates](#4-configuring-the-cluster-templates)
5. [Generating Manifests and the Installation ISO](#5-generating-manifests-and-the-installation-iso)
6. [Booting the Nodes](#6-booting-the-nodes)
7. [Monitoring Installation](#7-monitoring-installation)
8. [Post-Install Validation](#8-post-install-validation)
9. [KVM vs Bare Metal — Differences Summary](#9-kvm-vs-bare-metal--differences-summary)
10. [Post-Install Certificate Management](#10-post-install-certificate-management)

---

## 1. Prerequisites

### Bastion Host Requirements

The bastion host is the machine from which you run the ABI workflow. It can be your laptop, a VM, or the KVM host itself.

```bash
# Verify required tools
ansible --version          # >= 2.14
openshift-install version  # must match target OCP version (4.22)
oc version
git --version
python3 --version          # >= 3.9

# Install openshift-install if not present
OCP_VERSION=4.22.0
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz
tar xzf openshift-install-linux.tar.gz
sudo mv openshift-install /usr/local/bin/
```

### Pull Secret

Obtain your pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret). Save it to `~/.pull-secret.json`.

```bash
# Verify your pull secret is valid JSON
python3 -m json.tool ~/.pull-secret.json > /dev/null && echo "Pull secret OK"
```

### SSH Key Pair

```bash
# Generate a dedicated key pair for this cluster (or reuse an existing one)
ssh-keygen -t ed25519 -C "openshift-twonode" -f ~/.ssh/openshift-twonode-ed25519
cat ~/.ssh/openshift-twonode-ed25519.pub  # you will paste this into cluster.yml
```

### Clone the Required Repositories

```bash
git clone https://github.com/tosin2013/openshift-agent-install
git clone https://github.com/YOUR_ORG/openshift-twonode-guide

# Copy the two-node-fencing example into the openshift-agent-install clusters directory
cp -r openshift-twonode-guide/examples/two-node-fencing openshift-agent-install/clusters/
cd openshift-agent-install
```

---

## 2. KVM Environment Setup

> Skip this section if you are deploying to physical bare-metal servers. Go to [Section 3](#3-bare-metal-environment-setup).

### 2.1 Verify Host Resources

```bash
# Check available disk space (need ~400 GB for two OCP control-plane VMs)
lsblk
df -h

# Check available RAM (need ~32 GB minimum, 64 GB recommended)
free -h

# Verify hardware virtualization is enabled
grep -m1 -E "vmx|svm" /proc/cpuinfo && echo "Hardware virtualization: OK" || echo "ERROR: VT-x/AMD-V not found"

# Verify KVM module is loaded
lsmod | grep kvm
```

### 2.2 Install Required Packages

```bash
# RHEL/CentOS Stream 9
sudo dnf install -y qemu-kvm libvirt virt-install virt-manager \
  libvirt-client bridge-utils fence-agents-redfish python3-pip

sudo systemctl enable --now libvirtd

# Add your user to the libvirt group
sudo usermod -aG libvirt $(whoami)
newgrp libvirt
```

### 2.3 Install and Configure sushy-tools

`sushy-tools` provides a Redfish API on top of libvirt, allowing `fence_redfish` and the ABI to interact with KVM VMs as if they were real servers with BMCs.

```bash
# Install sushy-tools
pip3 install sushy-tools

# Create the sushy-emulator configuration file
sudo mkdir -p /etc/sushy
cat <<'EOF' | sudo tee /etc/sushy/sushy-emulator.conf
SUSHY_EMULATOR_LISTEN_IP = '0.0.0.0'
SUSHY_EMULATOR_LISTEN_PORT = 8000
SUSHY_EMULATOR_SSL_CERT = None
SUSHY_EMULATOR_SSL_KEY = None
SUSHY_EMULATOR_OS_CLOUD = None
SUSHY_EMULATOR_LIBVIRT_URI = 'qemu:///system'
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = True
SUSHY_EMULATOR_BOOT_LOADER_MAP = {}
EOF

# Create a systemd service for sushy-emulator
cat <<'EOF' | sudo tee /etc/systemd/system/sushy-emulator.service
[Unit]
Description=Sushy Redfish Emulator
After=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/sushy-emulator --config /etc/sushy/sushy-emulator.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sushy-emulator

# Verify sushy is responding
curl http://localhost:8000/redfish/v1/ | python3 -m json.tool
```

### 2.4 Create a Libvirt Network for the Cluster

```bash
cat <<'EOF' > /tmp/twonode-net.xml
<network>
  <name>twonode</name>
  <forward mode='nat'/>
  <bridge name='virbr-twonode' stp='on' delay='0'/>
  <ip address='192.168.150.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.150.200' end='192.168.150.254'/>
    </dhcp>
  </ip>
</network>
EOF

virsh net-define /tmp/twonode-net.xml
virsh net-start twonode
virsh net-autostart twonode
```

### 2.5 Create the KVM Virtual Machines

Create both nodes with **static MAC addresses**. Static MACs are critical — they prevent the MAC regeneration issue that broke the original Module 3 approach.

```bash
# Node 1 — control-plane-0
virt-install \
  --name openshift-node1 \
  --ram 16384 \
  --vcpus 8 \
  --os-variant rhel9.0 \
  --disk path=/var/lib/libvirt/images/openshift-node1.qcow2,size=200,format=qcow2 \
  --network network=twonode,mac=52:54:00:aa:bb:01 \
  --boot hd,cdrom \
  --noautoconsole \
  --import 2>/dev/null || true

# Node 2 — control-plane-1
virt-install \
  --name openshift-node2 \
  --ram 16384 \
  --vcpus 8 \
  --os-variant rhel9.0 \
  --disk path=/var/lib/libvirt/images/openshift-node2.qcow2,size=200,format=qcow2 \
  --network network=twonode,mac=52:54:00:aa:bb:02 \
  --boot hd,cdrom \
  --noautoconsole \
  --import 2>/dev/null || true

# Verify both VMs exist (they may be in shut-off state — that is fine)
virsh list --all | grep openshift-node
```

### 2.6 Map VM UUIDs to Redfish System URLs

sushy-tools uses the libvirt VM's UUID to identify each Redfish System.

```bash
# Get the UUID for each VM
NODE1_UUID=$(virsh domuuid openshift-node1)
NODE2_UUID=$(virsh domuuid openshift-node2)

echo "Node 1 Redfish URL: redfish-virtualmedia://localhost:8000/redfish/v1/Systems/${NODE1_UUID}"
echo "Node 2 Redfish URL: redfish-virtualmedia://localhost:8000/redfish/v1/Systems/${NODE2_UUID}"

# Verify sushy can see both systems
curl http://localhost:8000/redfish/v1/Systems/ | python3 -m json.tool

# Test power status of Node 1
curl http://localhost:8000/redfish/v1/Systems/${NODE1_UUID} | python3 -m json.tool | grep PowerState
```

Record these UUIDs — you will need them for `nodes.yml` and for the Pacemaker STONITH configuration.

---

## 3. Bare Metal Environment Setup

### 3.1 Pre-Deployment Checklist

Before configuring the cluster, verify each item:

```bash
# From the bastion, test Redfish connectivity to each node's BMC
curl -k -u <bmc-user>:<bmc-password> \
  https://<node1-bmc-ip>/redfish/v1/Systems/ | python3 -m json.tool

curl -k -u <bmc-user>:<bmc-password> \
  https://<node2-bmc-ip>/redfish/v1/Systems/ | python3 -m json.tool

# Verify fence_redfish can read power status
fence_redfish \
  -a <node1-bmc-ip> \
  -l <bmc-user> \
  -p <bmc-password> \
  -b "/redfish/v1/Systems/<system-id>" \
  -o status

# Note the MAC addresses for each node's cluster NIC
# (usually found in the Redfish EthernetInterfaces response or on a physical label)
```

### 3.2 Install fence-agents on the Bastion

```bash
sudo dnf install -y fence-agents-redfish
fence_redfish --help | head -20
```

### 3.3 Record Network Information

Before proceeding, record:

| Item | Node 1 | Node 2 |
|---|---|---|
| Cluster NIC MAC address | `52:54:00:...` | `52:54:00:...` |
| Planned static IP | `192.168.x.x` | `192.168.x.x` |
| BMC IP address | `10.x.x.x` | `10.x.x.x` |
| BMC username | | |
| BMC Redfish Systems URI | `/redfish/v1/Systems/<id>` | `/redfish/v1/Systems/<id>` |

---

## 4. Configuring the Cluster Templates

The configuration templates are in `clusters/two-node-fencing/` inside the `openshift-agent-install` directory.

### 4.1 Edit `cluster.yml`

```bash
vi clusters/two-node-fencing/cluster.yml
```

**Minimum required changes** (the template will not work without these):

| Parameter | Default | What to set |
|---|---|---|
| `cluster_name` | `twonode` | Your cluster name (no spaces, lowercase) |
| `base_domain` | `example.com` | Your real DNS domain (must be resolvable) |
| `pull_secret_path` | `~/pull-secret.json` | Path to your pull secret file |
| `ssh_public_key_path` | `~/.ssh/openshift-twonode-ed25519.pub` | Path to your SSH public key |
| `api_vips` | `192.168.49.253` | A free IP in your network |
| `app_vips` | `192.168.49.252` | A free IP in your network |
| `machine_network_cidrs` | `192.168.49.0/24` | Your cluster subnet |

All parameters explained below:

```yaml
# Cluster identity
cluster_name: two-node-fencing        # change to your desired cluster name
base_domain: example.com              # change to your base domain

# OpenShift version and topology
ocp_version: "4.22"
platform_type: baremetal
network_type: OVNKubernetes           # required for TNF — do not change
control_plane_replicas: 2
app_node_replicas: 0

# Feature set — required for TNF, do not remove
feature_set: TechPreviewNoUpgrade

# Networking
machine_network_cidr: 192.168.150.0/24   # adjust to your network
cluster_network_cidr: 10.128.0.0/14
service_network_cidr: 172.30.0.0/16
api_vip: 192.168.150.10                   # must be free, reachable from bastion
ingress_vip: 192.168.150.11               # must be free

# Authentication
pull_secret_file: ~/.pull-secret.json
ssh_public_key_file: ~/.ssh/openshift-twonode-ed25519.pub
```

### 4.2 Edit `nodes.yml`

```bash
vi clusters/two-node-fencing/nodes.yml
```

Set per-node values:

```yaml
nodes:
  - hostname: node1
    role: master
    rootDeviceHints:
      deviceName: /dev/sda
    interfaces:
      - name: ens3               # adjust to your NIC name
        macAddress: "52:54:00:aa:bb:01"   # static MAC — matches VM or physical NIC
    networkConfig:
      interfaces:
        - name: ens3
          type: ethernet
          state: up
          ipv4:
            enabled: true
            address:
              - ip: 192.168.150.21
                prefix-length: 24
            dhcp: false
      dns-resolver:
        config:
          server:
            - 192.168.150.1
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.150.1
            next-hop-interface: ens3
    bmc:
      address: "redfish-virtualmedia://localhost:8000/redfish/v1/Systems/<node1-uuid>"
      # For bare metal: "redfish-virtualmedia://<bmc-ip>/redfish/v1/Systems/<system-id>"
      username: admin
      password: changeme
      disableCertificateVerification: true

  - hostname: node2
    role: master
    rootDeviceHints:
      deviceName: /dev/sda
    interfaces:
      - name: ens3
        macAddress: "52:54:00:aa:bb:02"
    networkConfig:
      interfaces:
        - name: ens3
          type: ethernet
          state: up
          ipv4:
            enabled: true
            address:
              - ip: 192.168.150.22
                prefix-length: 24
            dhcp: false
      dns-resolver:
        config:
          server:
            - 192.168.150.1
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.150.1
            next-hop-interface: ens3
    bmc:
      address: "redfish-virtualmedia://localhost:8000/redfish/v1/Systems/<node2-uuid>"
      username: admin
      password: changeme
      disableCertificateVerification: true
```

---

## 5. Generating Manifests and the Installation ISO

```bash
cd openshift-agent-install

# Run the manifest generation playbook
ansible-playbook playbooks/create-manifests.yml \
  -e cluster_name=two-node-fencing \
  -v

# Verify the generated files
ls -la clusters/two-node-fencing/
# Expected: agent-config.yaml, install-config.yaml, and a manifests/ directory

# Verify featureSet is in install-config.yaml
grep -A5 "featureSet" clusters/two-node-fencing/install-config.yaml

# Generate the bootable ISO
openshift-install agent create image \
  --dir clusters/two-node-fencing/
  
# Verify the ISO was created
ls -lh clusters/two-node-fencing/agent.x86_64.iso
```

> **Note**: The ISO embeds the full configuration, including node IP addresses, MAC address-to-hostname mappings, and pull secret. It is specific to this cluster — do not reuse it for a different cluster.

---

## 6. Booting the Nodes

### KVM

```bash
ISO_PATH=$(realpath clusters/two-node-fencing/agent.x86_64.iso)

# Attach the ISO to Node 1 and boot from it
virsh change-media openshift-node1 sda "${ISO_PATH}" --config
virsh start openshift-node1

# Attach the ISO to Node 2 and boot from it
virsh change-media openshift-node2 sda "${ISO_PATH}" --config
virsh start openshift-node2

# Open a console to watch progress (optional)
virsh console openshift-node1
```

### Bare Metal via Redfish Virtual Media

```bash
# Mount ISO as virtual media and set one-time boot to CD-ROM for Node 1
curl -k -u <bmc-user>:<bmc-password> \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"Image\": \"http://<bastion-ip>:<port>/agent.x86_64.iso\", \"TransferMethod\": \"Stream\"}" \
  https://<node1-bmc-ip>/redfish/v1/Managers/<manager-id>/VirtualMedia/<media-id>/Actions/VirtualMedia.InsertMedia

# Power on Node 1
curl -k -u <bmc-user>:<bmc-password> \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"ResetType": "On"}' \
  https://<node1-bmc-ip>/redfish/v1/Systems/<system-id>/Actions/ComputerSystem.Reset

# Repeat for Node 2
```

> **Tip**: Most BMC vendors have vendor-specific tools that simplify virtual media mounting. Refer to your BMC vendor's documentation (Dell iDRAC, HP iLO, Lenovo XCC, Supermicro) for GUI or CLI alternatives.

---

## 7. Monitoring Installation

The installation happens in two phases. Run both wait commands from the bastion.

```bash
cd openshift-agent-install

# Phase 1: Bootstrap
# The bootstrap process configures the initial control-plane components.
# Takes approximately 15-25 minutes.
openshift-install agent wait-for bootstrap-complete \
  --dir clusters/two-node-fencing/ \
  --log-level info

# Phase 2: Full install complete
# Waits for all cluster operators to reach Available state.
# Takes approximately 30-60 minutes total.
openshift-install agent wait-for install-complete \
  --dir clusters/two-node-fencing/ \
  --log-level info

# On success, the output will show:
# INFO Install complete!
# INFO To access the cluster as the system:admin user when using 'oc', run:
#      export KUBECONFIG=<path>/auth/kubeconfig
# INFO Access the OpenShift web-console here: https://console-openshift-console.apps.<cluster>.<domain>
# INFO Login to the console with user: "kubeadmin", and password: "<generated-password>"
```

### Troubleshooting Stuck Installation

```bash
# Check agent events on the nodes (look for errors)
openshift-install agent wait-for bootstrap-complete \
  --dir clusters/two-node-fencing/ \
  --log-level debug 2>&1 | grep -E "error|Error|fail"

# Check which cluster operators are not yet available
export KUBECONFIG=clusters/two-node-fencing/auth/kubeconfig
oc get clusteroperators | grep -v "True.*False.*False"
```

---

## 8. Post-Install Validation

Run these checks after `wait-for install-complete` succeeds.

### 8.1 Kubernetes Cluster Health

```bash
export KUBECONFIG=clusters/two-node-fencing/auth/kubeconfig

# Nodes should both be in Ready state
oc get nodes -o wide

# All cluster operators should be Available=True, Progressing=False, Degraded=False
oc get clusteroperators

# API server and etcd operator status (note: etcd operator may show unusual status — see ADR-004)
oc get clusteroperator etcd
```

### 8.2 Pacemaker Cluster Health

SSH to either node and run:

```bash
ssh core@192.168.150.21

# Overall Pacemaker cluster status
sudo pcs status

# Verify STONITH resources are configured and started
sudo pcs stonith show

# Verify etcd resource is running on both nodes
sudo pcs resource show

# Check Corosync ring status
sudo corosync-cfgtool -s
```

Expected `pcs status` output (healthy):
```
Cluster name: <cluster-name>
Stack: corosync
Current DC: node1 (version ...) - partition with quorum
Last updated: ...
2 nodes configured
Resources: fence-node1, fence-node2, etcd:0 etcd:1 (clone)
Online: [ node1 node2 ]

Active resources:
  fence-node1    (stonith:fence_redfish): Started node2
  fence-node2    (stonith:fence_redfish): Started node1
  Clone Set: etcd-clone [etcd]:
    Started: [ node1 node2 ]
```

### 8.3 etcd Health

```bash
# From a node, check etcd member list and health
sudo podman exec etcd etcdctl member list \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).key

# Expected: 2 members, both showing "started" and correct peer URLs

sudo podman exec etcd etcdctl endpoint health \
  --cacert /etc/kubernetes/static-pod-resources/etcd-member/ca.crt \
  --cert /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).crt \
  --key /etc/kubernetes/static-pod-resources/etcd-member/system:etcd-peer:$(hostname).key

# Expected: "is healthy"
```

### 8.4 LVM Operator (Optional — Required for Demo 2)

```bash
# Install the LVM Operator via OperatorHub or CLI
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.22
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator to install
oc -n openshift-storage wait --for=condition=ready pod -l app=lvms-operator --timeout=120s

# Create an LVMCluster using available disks
# Adjust devicePaths to match your available disks (check with: lsblk)
oc apply -f - <<'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: twonode-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        deviceSelector:
          paths:
            - /dev/sdb   # adjust to your available disk
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
EOF

# Verify StorageClass was created
oc get storageclass | grep lvms
```

### 8.5 Smoke Test — Deploy a Sample Application

```bash
# Deploy a simple test application to verify the cluster is functional
oc new-project test-smoke
oc create deployment hello --image=quay.io/openshift/origin-hello-openshift
oc expose deployment hello --port=8080
oc expose service hello
oc get route hello

# Verify the application is reachable
curl http://$(oc get route hello -o jsonpath='{.spec.host}')
```

---

## 9. KVM vs Bare Metal — Differences Summary

| Step | KVM | Bare Metal |
|---|---|---|
| BMC type | sushy-tools (software, libvirt-backed) | Physical BMC (iDRAC, iLO, XCC, etc.) |
| Redfish URL format | `redfish-virtualmedia://localhost:8000/redfish/v1/Systems/<uuid>` | `redfish-virtualmedia://<bmc-ip>/redfish/v1/Systems/<system-id>` |
| Static MAC source | Set in libvirt VM XML definition | Physical NIC MAC (read from BMC or label) |
| ISO delivery | `virsh change-media` | Virtual media mount via BMC web/API |
| Node boot | `virsh start` | BMC power-on command |
| Network bridge | libvirt NAT or bridge network | Physical switch/VLAN |
| BMC network access | `localhost` or host IP | Dedicated BMC/IPMI network |
| `disableCertificateVerification` in nodes.yml | `true` (sushy HTTP) | `false` for production BMCs with valid certs |
| Fencing timeout | 10-15s (libvirt power-off is fast) | 30-60s (real BMC response varies) |

---

## 10. Post-Install Certificate Management

By default, the cluster uses self-signed certificates for the API server and Ingress. This
section covers installing the Red Hat cert-manager Operator and configuring Let's Encrypt
to issue publicly-trusted TLS certificates for all cluster endpoints.

> **Prerequisite**: Your `base_domain` must be a real, internet-resolvable domain you
> control. The default `example.com` placeholder will not work with Let's Encrypt.

For the full decision record, see [ADR-012](../adrs/012-cert-manager-lets-encrypt.md).
For the complete manifest set and detailed steps, see
[`examples/cert-manager/README.md`](../examples/cert-manager/README.md).

### Why DNS-01 Challenge

The TNF Ingress VIP (`192.168.49.252`) is on a private subnet — Let's Encrypt cannot
reach it from the internet for HTTP-01 validation. DNS-01 validates domain ownership via
a DNS TXT record, requiring only outbound HTTPS from the cluster to the DNS provider API.

### 10.1 Install cert-manager Operator

```bash
# Create namespaces, OperatorGroup, and Subscription
oc apply -f examples/cert-manager/namespace.yaml
oc apply -f examples/cert-manager/operator-group.yaml
oc apply -f examples/cert-manager/subscription.yaml

# Approve the install plan (Manual approval mode)
oc get installplan -n openshift-cert-manager-operator
oc patch installplan <INSTALLPLAN_NAME> \
  -n openshift-cert-manager-operator \
  --type merge \
  -p '{"spec":{"approved":true}}'

# Wait for operator to be ready
oc get csv -n openshift-cert-manager-operator --watch
# PHASE: Succeeded

# Verify cert-manager pods (operator deploys operands to the cert-manager namespace)
oc get pods -n cert-manager
# Expected: cert-manager-*, cert-manager-cainjector-*, cert-manager-webhook-*
```

### 10.2 Create DNS Provider Secret

Choose the template for your DNS provider from `examples/cert-manager/dns-secret-examples/`
and populate the credentials:

```bash
# Example for Cloudflare:
cp examples/cert-manager/dns-secret-examples/cloudflare-secret.yaml /tmp/dns-secret.yaml
# Edit: replace REPLACE_ME_CLOUDFLARE_API_TOKEN with your token
oc apply -f /tmp/dns-secret.yaml
```

### 10.3 Test with Staging ClusterIssuer

Always test with the staging issuer first to avoid Let's Encrypt production rate limits
(5 duplicate certificates per week):

```bash
# Edit cluster-issuer-staging.yaml:
#   1. Replace admin@REPLACE_ME_BASE_DOMAIN with your email
#   2. Uncomment the solver for your DNS provider
oc apply -f examples/cert-manager/cluster-issuer-staging.yaml

# Verify issuer is Ready
oc get clusterissuer letsencrypt-staging
# READY: True
```

Apply the wildcard certificate pointing to the staging issuer:

```bash
# Edit wildcard-certificate.yaml:
#   1. Replace REPLACE_ME_CLUSTER_NAME and REPLACE_ME_BASE_DOMAIN
#   2. Set issuerRef.name: letsencrypt-staging
oc apply -f /tmp/wildcard-certificate.yaml

# Monitor issuance (DNS TXT propagation takes 1-5 minutes)
oc get certificate wildcard-apps-cert -n openshift-ingress --watch
# READY: True
```

### 10.4 Promote to Production

Once staging succeeds:

```bash
# Apply production ClusterIssuer
oc apply -f examples/cert-manager/cluster-issuer-production.yaml

# Update certificate to use production issuer
# Edit: change issuerRef.name to letsencrypt-production
oc apply -f /tmp/wildcard-certificate.yaml

# Force re-issuance
oc delete certificaterequest -n openshift-ingress \
  $(oc get certificaterequest -n openshift-ingress -o name)

# Wait for production cert
oc get certificate wildcard-apps-cert -n openshift-ingress --watch
# READY: True
```

### 10.5 Configure Cluster Ingress

```bash
# Set the wildcard cert as the default certificate for all Routes
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type merge \
  -p '{"spec":{"defaultCertificate":{"name":"wildcard-apps-tls"}}}'

# Verify
oc get certificate -A
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate}'
```

### 10.6 Annotate Demo Routes (Optional)

To apply per-Route certificates instead of the shared wildcard:

```bash
oc annotate route <route-name> -n <namespace> \
  cert-manager.io/cluster-issuer=letsencrypt-production
```

> **Tip**: The wildcard approach is preferred for TNF clusters because it requires a
> single ACME DNS-01 challenge instead of one challenge per Route.
