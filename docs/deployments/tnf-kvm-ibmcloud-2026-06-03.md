# Deployment Record — TNF KVM on IBM Cloud (2026-06-03)

**Status**: SUCCESSFUL  
**Date**: June 3, 2026  
**Environment**: IBM Cloud bare-metal, RHEL 10, KVM  
**OpenShift Version**: 4.22.0-rc.5  
**Topology**: Two-Node OpenShift with Fencing (TNF) — `featureSet: TechPreviewNoUpgrade`

---

## Prerequisites

| Requirement | Details |
|---|---|
| Host OS | RHEL 10 bare-metal (IBM Cloud) |
| Host RAM | 64 GB minimum |
| Host disk | 1 TB data disk (`/dev/vdb`) for VM images |
| Host CPU | 8+ cores with VT-x/AMD-V |
| Pull secret | `~/pull-secret.json` from [cloud.redhat.com](https://cloud.redhat.com/openshift/install/pull-secret) |
| AWS credentials | `~/.aws/credentials` with Route53 write access |
| Route53 hosted zone | For your `<YOUR-BASE-DOMAIN>` |
| Internet access | For OCP binary downloads and Route53 API |

**Host environment variables required before running:**

```bash
export HOST_PRIVATE_IP="<your-host-private-ip>"   # e.g. from: ip route get 1 | awk '{print $7; exit}'
export EXTERNAL_IP="<your-public-ip>"              # IBM Cloud public IP assigned to the host
```

---

## Ordered Steps

### Step 0 — Bootstrap the host

```bash
export HOST_PRIVATE_IP="<your-host-private-ip>"
sudo -E bash ~/openshift-twonode-guide/scripts/bootstrap.sh
```

Installs: `qemu-kvm`, `libvirt`, `cockpit`, `dnsmasq`, `haproxy`, `fence-agents-redfish`,
`sushy-tools`, OCP 4.22 binaries, Ansible collections, SSH keypair, Cockpit admin user.

### Step 1 — DNS

```bash
cd ~/openshift-agent-install

# Add cluster DNS entries (api, api-int, *.apps → VIPs)
sudo ./hack/configure-dnsmasq-entries.sh add examples/two-node-fencing/cluster.yml

# MANDATORY gate — all 5 checks must be green before continuing
./hack/verify-dns-resolution.sh examples/two-node-fencing/cluster.yml
```

### Step 2 — Format storage disk

```bash
sudo mkfs.ext4 -L vmimages /dev/vdb
sudo mkdir -p /var/lib/libvirt/images
echo "LABEL=vmimages /var/lib/libvirt/images ext4 defaults 0 2" | sudo tee -a /etc/fstab
sudo mount /var/lib/libvirt/images
```

### Step 3 — VyOS router (semi-automated)

```bash
cd ~/openshift-agent-install
export ACTION=create
sudo bash hack/vyos-router.sh
```

**Manual step (~10 min):** Open Cockpit at `https://<YOUR-PUBLIC-IP>:9090`, navigate to
Virtual Machines → vyos-router → Console, login as `vyos`/`vyos`, run `install image`,
accept defaults, reboot, configure eth0 + SSH:

```
configure
set interfaces ethernet eth0 address 192.168.122.2/24
set protocols static route 0.0.0.0/0 next-hop 192.168.122.1
set service dns forwarding listen-address 192.168.122.2
set service dns forwarding allow-from 192.168.0.0/16
set service dns forwarding name-server 192.168.122.1
set service ssh port 22
set service ssh listen-address 0.0.0.0
commit
save
exit
```

**Apply VLAN config via SSH:**

```bash
sudo cp /root/vyos-config.sh ~/vyos-config.sh && sudo chown $USER:$USER ~/vyos-config.sh
sudo dnf install -y sshpass
sshpass -p 'vyos' scp -o StrictHostKeyChecking=no ~/vyos-config.sh vyos@192.168.122.2:/tmp/
sshpass -p 'vyos' ssh -o StrictHostKeyChecking=no vyos@192.168.122.2 'vbash /tmp/vyos-config.sh'
```

**Fix DNS listen-addresses for VLAN gateways:**

```bash
cat > /tmp/vyos-dns-fix.sh << 'EOF'
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure
set service dns forwarding listen-address 192.168.49.1
set service dns forwarding listen-address 192.168.50.1
set service dns forwarding listen-address 192.168.52.1
set service dns forwarding listen-address 192.168.54.1
set service dns forwarding listen-address 192.168.56.1
commit
save
exit
EOF
sshpass -p 'vyos' scp -o StrictHostKeyChecking=no /tmp/vyos-dns-fix.sh vyos@192.168.122.2:/tmp/
sshpass -p 'vyos' ssh -o StrictHostKeyChecking=no vyos@192.168.122.2 'vbash /tmp/vyos-dns-fix.sh'
```

### Step 4 — Deploy cluster

```bash
sudo bash ~/openshift-twonode-guide/scripts/deploy-tnf-kvm.sh
```

The script runs all phases automatically (~60 min total):

| Phase | Action |
|---|---|
| 1 | Preflight checks |
| 2 | sushy-emulator HTTPS on macvlan 192.168.122.10:8000 |
| 3 | Create KVM VMs, capture libvirt UUIDs |
| 4 | Build Redfish fencing addresses from UUIDs |
| 5 | Generate Agent-Based Installer ISO with fencing credentials injected |
| 6 | Attach ISO, start VMs |
| 7 | Background reboot watcher |
| 8 | `wait-for bootstrap-complete` |
| 8.5 | **etcd quorum recovery** (background — see Known Issues) |
| 9 | **Fencing secret patcher** (background — patches `certificateVerification: Disabled`) |
| 10 | `wait-for install-complete` |

### Step 5 — HAProxy (external access)

```bash
sudo tee /etc/haproxy/haproxy.cfg > /dev/null << 'HAPROXY'
global
    log 127.0.0.1 local2
    chroot /var/lib/haproxy
    pidfile /var/run/haproxy.pid
    maxconn 4000
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option tcplog
    retries 3
    timeout connect 10s
    timeout client 1m
    timeout server 1m

frontend api-server
    bind 0.0.0.0:6443
    default_backend api-backend

backend api-backend
    server api 192.168.49.253:6443 check

frontend machine-config
    bind 0.0.0.0:22623
    default_backend mcs-backend

backend mcs-backend
    server mcs 192.168.49.253:22623 check

frontend http-ingress
    bind 0.0.0.0:80
    default_backend ingress-http

backend ingress-http
    server ingress 192.168.49.252:80 check

frontend https-ingress
    bind 0.0.0.0:443
    default_backend ingress-https

backend ingress-https
    server ingress 192.168.49.252:443 check
HAPROXY

sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
sudo firewall-cmd --permanent --add-port={6443,22623,80,443}/tcp
sudo firewall-cmd --reload
```

### Step 5b — Route53 DNS

```bash
cd ~/openshift-agent-install
EXTERNAL_IP=<YOUR-PUBLIC-IP> bash hack/configure-route53-dns.sh add \
  examples/two-node-fencing/cluster.yml

# Verify propagation
dig @8.8.8.8 +short api.twonode.<YOUR-BASE-DOMAIN>   # should return <YOUR-PUBLIC-IP>
```

---

## Validation

```bash
export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig

# Node status
oc get nodes
# NAME               STATUS   ROLES                  AGE   VERSION
# openshift-node1    Ready    control-plane,master   60m   v1.25.x
# openshift-node2    Ready    control-plane,master   58m   v1.25.x

# All 35 cluster operators available
oc get co | grep -v "True.*False.*False"
# (no output = healthy)

# Pacemaker fencing active
ssh -i ~/.ssh/openshift-twonode-ed25519 core@192.168.49.21 sudo pcs status
# Online: [ openshift-node1 openshift-node2 ]
# stonith resources Started on both nodes
# etcd-clone Started on both nodes
```

---

## Known Issues

### Deterministic etcd quorum deadlock (Phase 8.5)

**Symptom**: After `bootstrap-complete`, node2's etcd enters an election loop.
`kube-apiserver` crash-loops because etcd has no quorum.
Cluster Etcd Operator (CEO) cannot provision node1's etcd manifests because the API is down.

**Root cause**: In TNF, node1 is the ABI rendezvous/bootstrap pivot. After bootstrap-complete,
node1 reboots into the installed RHCOS but the CEO has not yet written node1's `etcd-pod.yaml`.
Node2 starts etcd in existing 2-member mode and cannot elect a leader without node1's etcd.

**Automated fix (Phase 8.5 of `deploy-tnf-kvm.sh`):**
1. Background watcher detects etcd election loop on node2 via `crictl logs`.
2. Injects `--force-new-cluster` into `/etc/kubernetes/manifests/etcd-pod.yaml` on node2.
3. Waits for etcd to become healthy as a single-member cluster.
4. Restores original `etcd-pod.yaml` (removes `--force-new-cluster`).
5. Waits for `kube-apiserver` to recover from crash backoff (~5 min).
6. CEO detects node1 and automatically adds it to the etcd cluster.

**Log file**: `~/generated_assets/twonode/phase85-etcd-recovery.log`

### Self-signed certificate for sushy-emulator

`fence_redfish` always performs TLS handshake. `sushy-emulator` serves HTTPS via a
self-signed certificate generated by `scripts/setup-sushy-ssl.sh` with IP SAN for
`192.168.122.10`. Phase 9 of `deploy-tnf-kvm.sh` patches `certificateVerification: Disabled`
into the fencing secrets automatically.

---

## Rollback

```bash
# Destroy all cluster VMs and generated assets
sudo bash ~/openshift-twonode-guide/scripts/deploy-tnf-kvm.sh --destroy

# Remove Route53 DNS records (run before re-deploy or abandon)
cd ~/openshift-agent-install
EXTERNAL_IP=<YOUR-PUBLIC-IP> bash hack/configure-route53-dns.sh remove \
  examples/two-node-fencing/cluster.yml

# Full redeploy from scratch
sudo bash ~/openshift-twonode-guide/scripts/deploy-tnf-kvm.sh
```

---

## ADR References

- [ADR-002: Agent-Based Installer](../adrs/002-agent-based-installer.md) — etcd bootstrap ordering constraint
- [ADR-004: etcd Outside the Cluster](../adrs/004-etcd-outside-cluster.md) — Pacemaker-managed etcd
- [ADR-007: KVM/sushy-tools Dev Environment](../adrs/007-kvm-sushy-tools-dev-environment.md) — sushy-emulator HTTPS
