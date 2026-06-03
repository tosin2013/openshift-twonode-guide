#!/bin/bash
# deploy-tnf-kvm.sh — Two-Node OpenShift with Fencing (TNF) on KVM
#
# Forked from:
#   hack/deploy-on-kvm.sh      — VM creation and libvirt wiring
#   hack/configure-sushy-unix.sh — macvlan Redfish BMC emulator
#   hack/watch-and-reboot-kvm-vms.sh — reboot watcher
#
# TNF additions vs upstream:
#   - Creates VMs with pre-generated UUIDs before ISO generation
#   - Injects controlPlane.fencing.credentials into install-config.yaml
#   - Uses sushy-bmc macvlan interface (192.168.122.10) reachable from VMs
#   - Resource profile tuned for 2-node: 8 vCPU / 32 GB / 130 GB per node
#   - Targets VLAN 1924 (192.168.49.0/24) managed by VyOS router
#
# Usage:
#   sudo bash scripts/deploy-tnf-kvm.sh [--destroy] [--iso-only] [--skip-sushy]
#
# Environment overrides (all have defaults):
#   CLUSTER_NAME          twonode
#   GENERATED_ASSET_PATH  ~/generated_assets
#   FRAMEWORK_DIR         ~/openshift-agent-install
#   SUSHY_IP              192.168.122.10
#   SUSHY_PORT            8000
#   CP_CPU_CORES          8
#   CP_RAM_GB             32
#   DISK_SIZE             130
#   LIBVIRT_VM_PATH       /var/lib/libvirt/images

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
ok()      { echo -e "${GREEN}✓ $*${NC}"; }
info()    { echo -e "${BLUE}→ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}"; exit 1; }
section() { echo -e "\n${YELLOW}══ $* ══${NC}"; }

# ── Require root ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0 $*"

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo "~${ACTUAL_USER}")

# ── Defaults ─────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-twonode}"
GENERATED_ASSET_PATH="${GENERATED_ASSET_PATH:-${ACTUAL_HOME}/generated_assets}"
FRAMEWORK_DIR="${FRAMEWORK_DIR:-${ACTUAL_HOME}/openshift-agent-install}"
SITE_CONFIG_DIR="${FRAMEWORK_DIR}/examples/two-node-fencing"
CLUSTER_YML="${SITE_CONFIG_DIR}/cluster.yml"
NODES_YML="${SITE_CONFIG_DIR}/nodes.yml"

SUSHY_IP="${SUSHY_IP:-192.168.122.10}"
SUSHY_PORT="${SUSHY_PORT:-8000}"

CP_CPU_CORES="${CP_CPU_CORES:-8}"
CP_RAM_GB="${CP_RAM_GB:-32}"
DISK_SIZE="${DISK_SIZE:-130}"
LIBVIRT_VM_PATH="${LIBVIRT_VM_PATH:-/var/lib/libvirt/images}"

LIBVIRT_NETWORK="network=1924,model=e1000e"
ISO_PATH="${LIBVIRT_VM_PATH}/agent.x86_64.iso"
UUID_FILE="${GENERATED_ASSET_PATH}/${CLUSTER_NAME}/.tnf-uuids"

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_DESTROY=false
ISO_ONLY=false
SKIP_SUSHY=false

for arg in "$@"; do
  case $arg in
    --destroy)    DO_DESTROY=true ;;
    --iso-only)   ISO_ONLY=true ;;
    --skip-sushy) SKIP_SUSHY=true ;;
  esac
done

# ── Utility: extract node names from nodes.yml ───────────────────────────────
node_names() {
  yq e '.nodes[].hostname' "${NODES_YML}"
}

# ── Utility: get MAC address for a node/interface from nodes.yml ─────────────
get_mac() {
  local node_name=$1
  local iface=$2
  node="${node_name}" iface_name="${iface}" \
    yq -r '.nodes[] | select(.hostname == env(node)) | .interfaces[] | select(.name == env(iface_name)) | .mac_address' \
    "${NODES_YML}"
}

###############################################################################
# DESTROY mode — clean up all resources
###############################################################################
if [[ "${DO_DESTROY}" == true ]]; then
  section "Destroy — removing TNF KVM cluster resources"

  for node_name in $(node_names); do
    info "Stopping and undefining VM: ${node_name}"
    virsh destroy "${node_name}"  2>/dev/null || true
    virsh undefine "${node_name}" 2>/dev/null || true
    rm -f "${LIBVIRT_VM_PATH}/${CLUSTER_NAME}-${node_name}.qcow2"
    ok "VM ${node_name} removed"
  done

  rm -f "${ISO_PATH}"
  rm -f "${UUID_FILE}"
  ok "ISO and UUID cache removed"

  # Remove generated_assets cluster directory so next run starts from scratch
  if [[ -d "${GENERATED_ASSET_PATH}/${CLUSTER_NAME}" ]]; then
    rm -rf "${GENERATED_ASSET_PATH:?}/${CLUSTER_NAME}"
    ok "Generated assets directory removed"
  fi

  # Remove sushy-bmc interface
  if ip link show sushy-bmc &>/dev/null; then
    ip link del sushy-bmc 2>/dev/null || true
    ok "sushy-bmc interface removed"
  fi

  # Stop sushy-emulator
  systemctl stop  sushy-emulator.service 2>/dev/null || true
  systemctl disable sushy-emulator.service 2>/dev/null || true
  podman rm -f sushy-emulator 2>/dev/null || true
  ok "sushy-emulator stopped"

  ok "Destroy complete"
  exit 0
fi

###############################################################################
# Phase 1 — Preflight checks
###############################################################################
section "Phase 1 — Preflight"

command -v yq          &>/dev/null || die "yq not found — run bootstrap.sh first"
command -v virsh       &>/dev/null || die "virsh not found"
command -v virt-install &>/dev/null || die "virt-install not found"
command -v jq          &>/dev/null || die "jq not found"
command -v python3     &>/dev/null || die "python3 not found"

[[ -f "${CLUSTER_YML}" ]]  || die "Missing ${CLUSTER_YML}"
[[ -f "${NODES_YML}" ]]    || die "Missing ${NODES_YML}"
[[ -f "${ACTUAL_HOME}/pull-secret.json" ]] || die "Missing ~/pull-secret.json"
[[ -f "${ACTUAL_HOME}/.ssh/openshift-twonode-ed25519.pub" ]] || die "Missing SSH key — run bootstrap.sh"

virsh net-info 1924 &>/dev/null || die "libvirt network '1924' not found — run hack/vyos-router.sh first"
ok "libvirt network 1924 exists"

# Create asset directory and ensure it is owned by the actual user so ansible
# (run via sudo -u ACTUAL_USER) can write to it
mkdir -p "${GENERATED_ASSET_PATH}/${CLUSTER_NAME}"
chown "${ACTUAL_USER}:" "${GENERATED_ASSET_PATH}/${CLUSTER_NAME}"

###############################################################################
# Phase 2 — sushy-emulator (Redfish BMC on macvlan bridge, HTTPS)
#   Creates the sushy-bmc macvlan interface, then delegates to
#   setup-sushy-ssl.sh which generates a self-signed TLS cert with IP SAN and
#   starts sushy-emulator over HTTPS.
#
#   HTTPS is mandatory: fence_redfish (tnf-setup-job) always negotiates TLS
#   regardless of the URL scheme, so plain HTTP causes an SSL record layer
#   error.
###############################################################################
section "Phase 2 — sushy-emulator (Redfish BMC, HTTPS)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

setup_sushy() {
  info "Creating sushy-bmc macvlan interface on ${SUSHY_IP}…"
  if ! ip link show sushy-bmc &>/dev/null; then
    ip link add sushy-bmc link virbr0 type macvlan mode bridge
    ip addr add "${SUSHY_IP}/24" dev sushy-bmc
    ip link set sushy-bmc up
    ok "sushy-bmc interface created"
  else
    ok "sushy-bmc already exists"
  fi

  if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --zone=libvirt --query-port=${SUSHY_PORT}/tcp &>/dev/null; then
      firewall-cmd --zone=libvirt --add-port=${SUSHY_PORT}/tcp --permanent
      firewall-cmd --permanent --zone=trusted --add-interface=sushy-bmc
      firewall-cmd --permanent --add-port=${SUSHY_PORT}/tcp
      firewall-cmd --reload
      ok "firewalld: port ${SUSHY_PORT} opened"
    else
      ok "firewalld: port ${SUSHY_PORT} already open"
    fi
  fi

  # Delegate cert generation and container restart to the dedicated SSL script
  SUSHY_IP="${SUSHY_IP}" SUSHY_PORT="${SUSHY_PORT}" \
    bash "${SCRIPT_DIR}/setup-sushy-ssl.sh"
}

if [[ "${SKIP_SUSHY}" == true ]]; then
  warn "Skipping sushy setup (--skip-sushy)"
elif curl -sk "https://${SUSHY_IP}:${SUSHY_PORT}/redfish/v1/Managers" 2>/dev/null | grep -q "ManagerCollection"; then
  ok "sushy-emulator already running (HTTPS) at https://${SUSHY_IP}:${SUSHY_PORT}"
else
  setup_sushy
fi

###############################################################################
# Phase 3 — Create KVM VMs with pre-assigned UUIDs
#   VMs are created without an ISO here so we can capture their libvirt UUIDs
#   before ISO generation.  The ISO is attached in Phase 6.
###############################################################################
section "Phase 3 — Create KVM VMs (no ISO yet)"

create_vms() {
  for node_name in $(node_names); do
    if virsh domstate "${node_name}" &>/dev/null; then
      ok "VM ${node_name} already exists — skipping creation"
      continue
    fi

    local mac1
    local mac2
    mac1=$(get_mac "${node_name}" "enp1s0")
    mac2=$(get_mac "${node_name}" "enp2s0")

    info "Creating VM ${node_name} (${CP_CPU_CORES} vCPU / ${CP_RAM_GB} GB / ${DISK_SIZE} GB)…"
    info "  MAC1=${mac1}  MAC2=${mac2}"

    # Create the disk image first
    local disk_path="${LIBVIRT_VM_PATH}/${CLUSTER_NAME}-${node_name}.qcow2"
    if [[ ! -f "${disk_path}" ]]; then
      qemu-img create -f qcow2 "${disk_path}" "${DISK_SIZE}G"
    fi

    # Define the VM (--import so virt-install does not require a boot medium,
    # --noreboot keeps it shut off after definition)
    virt-install \
      -n "${node_name}" \
      --memory "$((CP_RAM_GB * 1024))" \
      --vcpus "sockets=1,cores=${CP_CPU_CORES},threads=1" \
      --disk "path=${disk_path},cache=none,format=qcow2" \
      --network "${LIBVIRT_NETWORK},mac=${mac1}" \
      --network "${LIBVIRT_NETWORK},mac=${mac2}" \
      --connect=qemu:///system \
      -v --memballoon none --cpu host-passthrough \
      --autostart --noautoconsole --virt-type kvm \
      --features kvm_hidden=on \
      --controller type=scsi,model=virtio-scsi \
      --graphics vnc,listen=0.0.0.0 \
      --os-variant rhel8.6 \
      --import \
      --noreboot 2>&1 | tail -5

    ok "VM ${node_name} defined"
  done
}

if [[ "${ISO_ONLY}" == false ]]; then
  create_vms
fi

###############################################################################
# Phase 4 — Capture libvirt UUIDs → build fencing credentials
###############################################################################
section "Phase 4 — Capture VM UUIDs for fencing"

declare -a FENCING_UUIDS=()
declare -a FENCING_ADDRESSES=()
NODE_NAMES_ARRAY=()

for node_name in $(node_names); do
  NODE_NAMES_ARRAY+=("${node_name}")
  if [[ "${ISO_ONLY}" == false ]]; then
    UUID=$(virsh domuuid "${node_name}" 2>/dev/null) || die "Cannot get UUID for ${node_name}"
  else
    # In ISO-only mode read from cache
    [[ -f "${UUID_FILE}" ]] || die "UUID cache not found at ${UUID_FILE} — run without --iso-only first"
    UUID=$(grep "^${node_name}=" "${UUID_FILE}" | cut -d= -f2)
    [[ -n "${UUID}" ]] || die "UUID for ${node_name} not found in cache"
  fi
  FENCING_UUIDS+=("${UUID}")
  FENCING_ADDRESSES+=("redfish-virtualmedia+https://${SUSHY_IP}:${SUSHY_PORT}/redfish/v1/Systems/${UUID}")
  info "${node_name} → UUID ${UUID}"
done

# Persist UUIDs for --iso-only reruns
mkdir -p "$(dirname ${UUID_FILE})"
> "${UUID_FILE}"
for i in "${!NODE_NAMES_ARRAY[@]}"; do
  echo "${NODE_NAMES_ARRAY[$i]}=${FENCING_UUIDS[$i]}" >> "${UUID_FILE}"
done
ok "UUIDs cached at ${UUID_FILE}"

###############################################################################
# Phase 5 — Generate Agent ISO with fencing credentials
#   Steps:
#   a) Run ansible playbook to generate install-config.yaml + agent-config.yaml
#   b) Inject controlPlane.fencing.credentials via Python
#   c) Run openshift-install agent create image
###############################################################################
section "Phase 5 — Generate Agent ISO with fencing credentials"

ASSET_DIR="${GENERATED_ASSET_PATH}/${CLUSTER_NAME}"

# 5a — Run ansible playbook (same as first half of create-iso.sh)
info "Running ansible-playbook to generate manifests…"
cd "${FRAMEWORK_DIR}"
sudo -u "${ACTUAL_USER}" ansible-playbook \
  -e "@${SITE_CONFIG_DIR}/cluster.yml" \
  -e "@${SITE_CONFIG_DIR}/nodes.yml" \
  -e "generated_asset_path=${GENERATED_ASSET_PATH}" \
  playbooks/create-manifests.yml -v \
  || die "Ansible playbook failed"
ok "Manifests generated in ${ASSET_DIR}/"

# 5b — Inject fencing credentials into install-config.yaml using Python
info "Injecting controlPlane.fencing.credentials into install-config.yaml…"

# Write fencing data to a temp CSV file: hostname,address
FENCING_DATA_FILE=$(mktemp /tmp/tnf-fencing-XXXX.csv)
for i in "${!NODE_NAMES_ARRAY[@]}"; do
  echo "${NODE_NAMES_ARRAY[$i]},${FENCING_ADDRESSES[$i]}" >> "${FENCING_DATA_FILE}"
done

python3 - "${ASSET_DIR}/install-config.yaml" "${FENCING_DATA_FILE}" << 'PYEOF'
import yaml, sys

ic_path = sys.argv[1]
data_file = sys.argv[2]

with open(ic_path) as f:
    ic = yaml.safe_load(f)

credentials = []
with open(data_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        hostname, address = line.split(",", 1)
        credentials.append({
            "username": "admin",
            "password": "admin",
            "address": address,
            "hostName": hostname,
        })

if not isinstance(ic.get("controlPlane"), dict):
    ic["controlPlane"] = {}

ic["controlPlane"].setdefault("name", "master")
ic["controlPlane"]["fencing"] = {"credentials": credentials}

with open(ic_path, "w") as f:
    yaml.dump(ic, f, default_flow_style=False, allow_unicode=True)

print(f"Fencing credentials injected for {len(credentials)} nodes:")
for c in credentials:
    print(f"  {c['hostName']} → {c['address']}")
PYEOF

rm -f "${FENCING_DATA_FILE}"

ok "install-config.yaml patched with fencing credentials"

# Verify
if grep -q "fencing" "${ASSET_DIR}/install-config.yaml"; then
  ok "Fencing block confirmed in install-config.yaml"
  grep -A6 "fencing:" "${ASSET_DIR}/install-config.yaml"
else
  die "Fencing block missing from install-config.yaml"
fi

# 5c — Run openshift-install agent create image
info "Running openshift-install agent create image…"
sudo -u "${ACTUAL_USER}" "${FRAMEWORK_DIR}/bin/openshift-install" agent create image \
  --dir "${ASSET_DIR}" \
  || die "openshift-install agent create image failed"

ok "ISO generated: ${ASSET_DIR}/agent.x86_64.iso"
ls -lh "${ASSET_DIR}/agent.x86_64.iso"

if [[ "${ISO_ONLY}" == true ]]; then
  ok "--iso-only: stopping after ISO generation"
  exit 0
fi

###############################################################################
# Phase 6 — Recreate VMs with ISO as first boot device
#   virt-install --cdrom creates a proper SATA cdrom (sda, boot order 1) with
#   the main disk as boot order 2.  This is more reliable than attaching a
#   cdrom to an already-defined VM on q35 machines.
###############################################################################
section "Phase 6 — Recreate VMs with cdrom and boot"

info "Copying ISO to ${ISO_PATH}…"
cp -f "${ASSET_DIR}/agent.x86_64.iso" "${ISO_PATH}"
ok "ISO at ${ISO_PATH} ($(du -sh ${ISO_PATH} | cut -f1))"

# Indexed loop so we can pass the Phase-4 UUID to --uuid, ensuring the
# recreated VM has the same UUID that was embedded in the ISO's
# install-config.yaml fencing credentials.  Without this, virt-install
# assigns a new random UUID and fence_redfish can no longer find the VM
# in the sushy registry.
for idx in "${!NODE_NAMES_ARRAY[@]}"; do
  node_name="${NODE_NAMES_ARRAY[$idx]}"
  node_uuid="${FENCING_UUIDS[$idx]}"
  mac1=$(get_mac "${node_name}" "enp1s0")
  mac2=$(get_mac "${node_name}" "enp2s0")
  disk_path="${LIBVIRT_VM_PATH}/${CLUSTER_NAME}-${node_name}.qcow2"

  # Destroy and undefine existing definition (disk is kept)
  virsh destroy  "${node_name}" 2>/dev/null || true
  virsh undefine "${node_name}" 2>/dev/null || true

  info "Creating ${node_name} with cdrom (boot order: cdrom→disk, UUID: ${node_uuid})…"
  virt-install \
    -n "${node_name}" \
    --uuid "${node_uuid}" \
    --memory "$((CP_RAM_GB * 1024))" \
    --vcpus "sockets=1,cores=${CP_CPU_CORES},threads=1" \
    --disk "path=${disk_path},cache=none,format=qcow2" \
    --cdrom "${ISO_PATH}" \
    --network "${LIBVIRT_NETWORK},mac=${mac1}" \
    --network "${LIBVIRT_NETWORK},mac=${mac2}" \
    --connect=qemu:///system \
    -v --memballoon none --cpu host-passthrough \
    --autostart --noautoconsole --virt-type kvm \
    --features kvm_hidden=on \
    --controller type=scsi,model=virtio-scsi \
    --graphics vnc,listen=0.0.0.0 \
    --os-variant rhel8.6 \
    --boot cdrom,hd 2>&1 | tail -3

  ok "${node_name} running (cdrom boot order 1 → disk boot order 2)"
done

###############################################################################
# Phase 7 — Persistent reboot watcher (background)
#   Nodes reboot MULTIPLE times during installation (image write → firstboot
#   → MCO → kube-apiserver rollout).  A one-shot watcher misses later reboots.
#   This watcher polls every 15s and restarts any shut-off VM until a sentinel
#   file is written by Phase 8 on install-complete, or a 90-min safety timeout.
#   Forked from hack/watch-and-reboot-kvm-vms.sh
###############################################################################
section "Phase 7 — Persistent reboot watcher (background)"

WATCHER_SCRIPT=$(mktemp /tmp/tnf-watcher-XXXX.sh)
WATCHER_LOG="${ASSET_DIR}/reboot-watcher.log"
WATCHER_SENTINEL="${WATCHER_LOG}.done"

cat > "${WATCHER_SCRIPT}" << 'WATCHER'
#!/bin/bash
node_names_str="$1"
log_file="$2"
sentinel="${log_file}.done"
TIMEOUT_MINS=90
END_TIME=$(( $(date +%s) + TIMEOUT_MINS * 60 ))

VM_ARR=($node_names_str)
echo "$(date): Persistent watcher started for: ${VM_ARR[*]} (timeout ${TIMEOUT_MINS}m)" | tee -a "${log_file}"

while [[ $(date +%s) -lt ${END_TIME} ]]; do
  [[ -f "${sentinel}" ]] && \
    echo "$(date): Sentinel found — watcher exiting cleanly" | tee -a "${log_file}" && exit 0

  for vm in "${VM_ARR[@]}"; do
    state=$(virsh domstate "${vm}" 2>/dev/null | tr -d ' ')
    if [[ "${state}" == "shutoff" ]]; then
      echo "$(date): ${vm} is shut off — restarting..." | tee -a "${log_file}"
      virsh start "${vm}" 2>/dev/null && \
        echo "$(date): ${vm} restarted" | tee -a "${log_file}" || \
        echo "$(date): WARNING: could not start ${vm}" | tee -a "${log_file}"
      sleep 10
    fi
  done
  sleep 15
done

echo "$(date): Safety timeout (${TIMEOUT_MINS}m) reached — watcher exiting" | tee -a "${log_file}"
WATCHER
chmod +x "${WATCHER_SCRIPT}"

NODE_LIST=$(node_names | tr '\n' ' ')
nohup bash "${WATCHER_SCRIPT}" "${NODE_LIST}" "${WATCHER_LOG}" >> "${WATCHER_LOG}" 2>&1 &
WATCHER_PID=$!
ok "Persistent reboot watcher PID ${WATCHER_PID} — log: ${WATCHER_LOG}"

###############################################################################
# Phase 8 — Monitor installation
###############################################################################
section "Phase 8 — Monitoring installation"

echo ""
echo "  ISO:       ${ASSET_DIR}/agent.x86_64.iso"
echo "  Assets:    ${ASSET_DIR}/"
echo "  Watcher:   ${ASSET_DIR}/reboot-watcher.log"
echo ""
echo "  Run these as ${ACTUAL_USER} to track progress:"
echo ""
echo "  ${FRAMEWORK_DIR}/bin/openshift-install agent wait-for bootstrap-complete \\"
echo "    --dir ${ASSET_DIR}/ --log-level=info"
echo ""
echo "  ${FRAMEWORK_DIR}/bin/openshift-install agent wait-for install-complete \\"
echo "    --dir ${ASSET_DIR}/ --log-level=info"
echo ""
echo "  After install-complete:"
echo "    oc --kubeconfig ${ASSET_DIR}/auth/kubeconfig get nodes"
echo "    oc --kubeconfig ${ASSET_DIR}/auth/kubeconfig get co"
echo ""

# Drop to wait-for bootstrap-complete (runs as actual_user)
info "Waiting for bootstrap-complete…"
sudo -u "${ACTUAL_USER}" "${FRAMEWORK_DIR}/bin/openshift-install" agent wait-for bootstrap-complete \
  --dir "${ASSET_DIR}/" \
  --log-level=info \
  || warn "bootstrap-complete timed out — check VM consoles in Cockpit"

###############################################################################
# Phase 8.5 — etcd quorum recovery (background)
#
# In 2-node TNF, node1 is the ABI rendezvous/bootstrap pivot.  The bootstrap
# control plane runs on node1 inside the live ISO environment.  After
# bootstrap-complete, node1 reboots into the installed RHCOS — but the Cluster
# Etcd Operator (CEO) has not yet had time to run its installer pods on node1.
# Node2 has etcd-pod.yaml (written during bootstrap), node1 does not.
#
# Result without this phase:
#   - node2 etcd starts in "existing" 2-member mode, cannot elect leader
#   - kube-apiserver crash-loops (can't reach etcd)
#   - CEO can't schedule installer pods for node1 (no API)  → circular deadlock
#
# Fix: after bootstrap-complete, this background watcher detects the quorum
# loss (etcd election loop in logs), injects --force-new-cluster into node2's
# etcd manifest, waits for a healthy single-member etcd, then restores the
# original manifest.  Once the kube-apiserver is up the CEO self-heals node1.
###############################################################################
section "Phase 8.5 — etcd quorum recovery watcher (background)"

NODE1_IP=$(yq -r '.nodes[] | select(.hostname == "openshift-node1") | .interfaces[0].ip_address' "${NODES_YML}" 2>/dev/null || echo "192.168.49.21")
NODE2_IP=$(yq -r '.nodes[] | select(.hostname == "openshift-node2") | .interfaces[0].ip_address' "${NODES_YML}" 2>/dev/null || echo "192.168.49.22")
PHASE85_LOG="${ASSET_DIR}/phase85-etcd-recovery.log"
SSH_KEY="${ACTUAL_HOME}/.ssh/openshift-twonode-ed25519"

cat > /tmp/tnf-phase85-XXXX.sh << PHASE85_SCRIPT
#!/bin/bash
node1_ip="${NODE1_IP}"
node2_ip="${NODE2_IP}"
ssh_key="${SSH_KEY}"
log="${PHASE85_LOG}"
kubeconfig="${ASSET_DIR}/auth/kubeconfig"
oc_cmd="sudo -u ${ACTUAL_USER} oc --kubeconfig \${kubeconfig}"
TIMEOUT_END=\$(( \$(date +%s) + 1800 ))  # 30-min safety timeout

ssh_node2() { ssh -i "\${ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "core@\${node2_ip}" "\$@" 2>/dev/null; }
ssh_node1() { ssh -i "\${ssh_key}" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "core@\${node1_ip}" "\$@" 2>/dev/null; }

echo "\$(date): Phase 8.5 etcd quorum recovery watcher started" | tee -a "\${log}"

# Wait for kubeconfig to appear (API up) or detect etcd quorum loss
while [[ \$(date +%s) -lt \${TIMEOUT_END} ]]; do
  # Happy path: API is already up — no action needed
  if [[ -f "\${kubeconfig}" ]] && sudo -u ${ACTUAL_USER} oc --kubeconfig "\${kubeconfig}" get nodes &>/dev/null 2>&1; then
    echo "\$(date): API reachable — etcd quorum OK, Phase 8.5 exiting cleanly" | tee -a "\${log}"
    exit 0
  fi

  # Detect quorum loss: etcd logs show election loop
  etcd_log=\$(ssh_node2 "sudo crictl logs \$(sudo crictl ps --name '^etcd\$' -q 2>/dev/null | head -1) 2>&1 | tail -5" 2>/dev/null)
  if echo "\${etcd_log}" | grep -q "MsgPreVote\|sent MsgPreVote\|ReadIndex response took too long"; then
    echo "\$(date): Detected etcd election loop — node1 missing etcd-pod.yaml, applying --force-new-cluster fix" | tee -a "\${log}"

    # Backup and inject --force-new-cluster
    ssh_node2 "sudo cp /etc/kubernetes/manifests/etcd-pod.yaml /tmp/etcd-pod.yaml.bak && \
      sudo python3 -c \"
import json
with open('/etc/kubernetes/manifests/etcd-pod.yaml') as f: pod = json.load(f)
for c in pod['spec']['containers']:
  if c['name'] == 'etcd' and isinstance(c.get('command'), list) and len(c['command']) >= 3:
    if '--force-new-cluster' not in c['command'][2]:
      c['command'][2] = c['command'][2].replace(
        'exec nice -n -19 ionice -c2 -n0 etcd ',
        'exec nice -n -19 ionice -c2 -n0 etcd --force-new-cluster '
      )
with open('/tmp/etcd-pod-force.yaml', 'w') as f: json.dump(pod, f)
\" && sudo cp /tmp/etcd-pod-force.yaml /etc/kubernetes/manifests/etcd-pod.yaml" \
      && echo "\$(date): Injected --force-new-cluster, kubelet will restart etcd" | tee -a "\${log}" \
      || { echo "\$(date): ERROR: failed to inject --force-new-cluster" | tee -a "\${log}"; sleep 30; continue; }

    # Wait for etcd to become healthy as single-member
    echo "\$(date): Waiting up to 3 min for etcd to start in single-member mode" | tee -a "\${log}"
    for i in \$(seq 1 18); do
      sleep 10
      etcd_ctr=\$(ssh_node2 "sudo crictl ps --name '^etcd\$' -q 2>/dev/null | head -1")
      if [[ -n "\${etcd_ctr}" ]]; then
        health=\$(ssh_node2 "sudo crictl exec \${etcd_ctr} sh -c '
          unset ETCDCTL_ENDPOINTS ETCDCTL_CACERT ETCDCTL_CERT ETCDCTL_KEY
          etcdctl --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
            --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node2.crt \
            --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-openshift-node2.key \
            --endpoints=https://localhost:2379 endpoint health 2>&1'" 2>/dev/null)
        if echo "\${health}" | grep -q "is healthy"; then
          echo "\$(date): etcd single-member healthy — restoring original manifest" | tee -a "\${log}"
          ssh_node2 "sudo cp /tmp/etcd-pod.yaml.bak /etc/kubernetes/manifests/etcd-pod.yaml"
          echo "\$(date): Original manifest restored — waiting for kube-apiserver (up to 8 min)" | tee -a "\${log}"

          # Wait for API to come up (kube-apiserver max backoff = 5 min)
          for j in \$(seq 1 48); do
            sleep 10
            [[ -f "\${kubeconfig}" ]] && \
              sudo -u ${ACTUAL_USER} oc --kubeconfig "\${kubeconfig}" get nodes &>/dev/null 2>&1 && {
              echo "\$(date): API is up — Phase 8.5 recovery complete" | tee -a "\${log}"
              exit 0
            }
          done
          echo "\$(date): WARNING: API did not come up in 8 min after etcd recovery" | tee -a "\${log}"
          exit 1
        fi
      fi
    done
    echo "\$(date): WARNING: etcd did not become healthy in 3 min — restoring original manifest" | tee -a "\${log}"
    ssh_node2 "sudo cp /tmp/etcd-pod.yaml.bak /etc/kubernetes/manifests/etcd-pod.yaml" || true
  fi
  sleep 15
done
echo "\$(date): Phase 8.5 safety timeout reached" | tee -a "\${log}"
PHASE85_SCRIPT
chmod +x /tmp/tnf-phase85-XXXX.sh

nohup bash /tmp/tnf-phase85-XXXX.sh >> "${PHASE85_LOG}" 2>&1 &
PHASE85_PID=$!
ok "Phase 8.5 etcd quorum recovery watcher PID ${PHASE85_PID} — log: ${PHASE85_LOG}"

###############################################################################
# Phase 9 — Patch fencing secrets for self-signed TLS (background)
#
# This MUST run concurrently with wait-for install-complete, not after it.
# The deadlock otherwise is:
#   wait-for install-complete blocks on etcd operator
#   etcd operator blocks on tnf-setup-job
#   tnf-setup-job fails because fencing secrets have certificateVerification=""
#   Phase 9 never runs because it is after wait-for install-complete
#
# Two issues patched:
#   1. certificateVerification="" → "Disabled" (installer leaves it blank)
#   2. address UUID — with --uuid in Phase 6 this should already be correct,
#      but we patch it defensively using the Phase-4 UUIDs from FENCING_ADDRESSES
###############################################################################
section "Phase 9 — Fencing secret patcher (background)"

KUBECONFIG="${ASSET_DIR}/auth/kubeconfig"
OC="sudo -u ${ACTUAL_USER} oc --kubeconfig ${KUBECONFIG}"
PHASE9_LOG="${ASSET_DIR}/phase9-fencing-patch.log"

# Write fencing address map for the background subshell
FENCING_MAP_FILE=$(mktemp /tmp/tnf-fencing-map-XXXX)
for i in "${!NODE_NAMES_ARRAY[@]}"; do
  echo "${NODE_NAMES_ARRAY[$i]} ${FENCING_ADDRESSES[$i]}" >> "${FENCING_MAP_FILE}"
done

cat > /tmp/tnf-phase9-XXXX.sh << PHASE9_SCRIPT
#!/bin/bash
kubeconfig="${KUBECONFIG}"
oc_cmd="sudo -u ${ACTUAL_USER} oc --kubeconfig \${kubeconfig}"
log="${PHASE9_LOG}"
fencing_map="${FENCING_MAP_FILE}"

echo "\$(date): Phase 9 background patcher started" | tee -a "\${log}"

# Wait for kubeconfig to exist
for i in \$(seq 1 60); do
  [[ -f "\${kubeconfig}" ]] && break
  echo "\$(date): waiting for kubeconfig… (\${i}/60)" | tee -a "\${log}"
  sleep 10
done

# Wait for all fencing secrets to be created, then patch them
declare -A patched=()
TIMEOUT_END=\$(( \$(date +%s) + 1800 ))  # 30-min safety timeout

while [[ \$(date +%s) -lt \${TIMEOUT_END} ]]; do
  all_patched=true
  while IFS=' ' read -r node_name address; do
    secret="fencing-credentials-\${node_name}"
    [[ -n "\${patched[\${node_name}]}" ]] && continue

    if ! \${oc_cmd} get secret "\${secret}" -n openshift-etcd &>/dev/null 2>&1; then
      all_patched=false
      continue
    fi

    # Patch certificateVerification and address together
    \${oc_cmd} patch secret "\${secret}" -n openshift-etcd \
      --type=merge \
      -p "{\"stringData\":{\"certificateVerification\":\"Disabled\",\"address\":\"\${address}\"}}" \
      2>/dev/null && {
        patched[\${node_name}]=1
        echo "\$(date): Patched \${secret} (certificateVerification=Disabled, address=\${address})" | tee -a "\${log}"
      }
  done < "\${fencing_map}"

  if [[ "\${all_patched}" == true ]]; then
    echo "\$(date): All fencing secrets patched — deleting tnf-setup-job" | tee -a "\${log}"
    # Delete any existing failed job so the operator recreates it with patched secrets
    \${oc_cmd} delete job tnf-setup-job -n openshift-etcd 2>/dev/null || true

    # Wait for success
    for i in \$(seq 1 60); do
      status=\$(\${oc_cmd} get job tnf-setup-job -n openshift-etcd \
        -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
      if [[ "\${status}" == "1" ]]; then
        echo "\$(date): tnf-setup-job SUCCEEDED" | tee -a "\${log}"
        exit 0
      fi
      failed=\$(\${oc_cmd} get job tnf-setup-job -n openshift-etcd \
        -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
      echo "\$(date): tnf-setup-job waiting… succeeded=\${status:-pending} failed=\${failed}" | tee -a "\${log}"
      sleep 10
    done
    echo "\$(date): WARNING: tnf-setup-job did not complete in time" | tee -a "\${log}"
    exit 1
  fi
  sleep 10
done
echo "\$(date): Phase 9 timeout reached" | tee -a "\${log}"
PHASE9_SCRIPT
chmod +x /tmp/tnf-phase9-XXXX.sh

nohup bash /tmp/tnf-phase9-XXXX.sh >> "${PHASE9_LOG}" 2>&1 &
PHASE9_PID=$!
ok "Phase 9 fencing patcher running in background (PID ${PHASE9_PID}) — log: ${PHASE9_LOG}"

info "Waiting for install-complete…"
sudo -u "${ACTUAL_USER}" "${FRAMEWORK_DIR}/bin/openshift-install" agent wait-for install-complete \
  --dir "${ASSET_DIR}/" \
  --log-level=info \
  || warn "install-complete timed out — check: tail -f ${PHASE9_LOG}"

# Signal the reboot watcher to stop
touch "${WATCHER_SENTINEL}" 2>/dev/null || true

section "Deployment Complete"
if [[ -f "${KUBECONFIG}" ]]; then
  ${OC} get nodes -o wide 2>/dev/null || true
  ${OC} get co 2>/dev/null | head -15 || true
  echo ""

  # Derive actual base domain from cluster.yml
  BASE_DOMAIN=$(yq -r '.base_domain' "${CLUSTER_YML}" 2>/dev/null || echo "example.com")

  KUBEADMIN_PASS="${ASSET_DIR}/auth/kubeadmin-password"
  CREDS_FILE="${ACTUAL_HOME}/cluster-credentials.txt"

  # Write a credentials summary to ~/cluster-credentials.txt (never print password to stdout)
  cat > "${CREDS_FILE}" <<EOFCREDS
============================================================
 OpenShift Cluster Credentials — ${CLUSTER_NAME}.${BASE_DOMAIN}
 Generated: $(date)
============================================================
 API URL  : https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443
 Console  : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
 KUBECONFIG: ${KUBECONFIG}

 Username : kubeadmin
 Password : $(cat "${KUBEADMIN_PASS}" 2>/dev/null || echo "<see ${KUBEADMIN_PASS}>")

⚠  Rotate kubeadmin credentials after first login.
   oc create secret generic kubeadmin ... OR disable via identity provider.
============================================================
EOFCREDS
  chown "${ACTUAL_USER}:${ACTUAL_USER}" "${CREDS_FILE}"
  chmod 600 "${CREDS_FILE}"

  ok "KUBECONFIG : ${KUBECONFIG}"
  ok "Console   : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
  ok "API       : https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
  ok "Credentials saved → ${CREDS_FILE}  (password NOT echoed to terminal)"
fi
