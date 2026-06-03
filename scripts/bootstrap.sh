#!/bin/bash
# bootstrap.sh — Idempotent host bootstrap for Two-Node OpenShift on IBM Cloud KVM
#
# Based on tosin2013/openshift-agent-install e2e-tests/bootstrap_env.sh but adapted for:
#   - OCP 4.22.0-rc.5 (pinned, not auto-detected stable)
#   - Deployment ORDER: packages → OCP binaries → Ansible collections →
#                       dnsmasq setup → cockpit user → registry auth
#   - NO configure_infrastructure / vyos-router.sh here (Phase 2 only)
#   - IBM Cloud bare-metal: firewalld enabled, dnsmasq listens on host private IP
#
# Usage: sudo bash ~/openshift-twonode-guide/scripts/bootstrap.sh
# Re-run safe: all steps are idempotent.

set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${BLUE}→ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}"; exit 1; }
section() { echo -e "\n${YELLOW}══ $* ══${NC}"; }

# ── Require root ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo "~${ACTUAL_USER}")
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
FRAMEWORK_DIR="${ACTUAL_HOME}/openshift-agent-install"

# ── Configuration ────────────────────────────────────────────────────────────
OCP_VERSION="${OCP_VERSION:-4.22.0-rc.5}"
CLUSTER_NAME="${CLUSTER_NAME:-twonode}"
# Set HOST_PRIVATE_IP to your host's private network IP (e.g. from: ip route get 1 | awk '{print $7; exit}')
HOST_PRIVATE_IP="${HOST_PRIVATE_IP:-}"
[[ -z "$HOST_PRIVATE_IP" ]] && die "Set HOST_PRIVATE_IP env var to your host's private IP before running (e.g. export HOST_PRIVATE_IP=10.0.0.1)"

section "Phase 0A — System Packages"

PKGS=(
  qemu-kvm libvirt libvirt-client libvirt-daemon libvirt-daemon-driver-qemu
  virt-install cockpit cockpit-machines
  fence-agents-redfish dnsmasq haproxy
  nmstate bind-utils libguestfs cloud-init
  podman selinux-policy-targeted policycoreutils-python-utils
  python3-pip ansible-core
)

for pkg in "${PKGS[@]}"; do
  if rpm -q "$pkg" &>/dev/null; then
    ok "$pkg already installed"
  else
    info "Installing $pkg…"
    dnf install -y "$pkg" 2>&1 | tail -2
    ok "$pkg installed"
  fi
done

# ── libvirt / cockpit services ───────────────────────────────────────────────
systemctl enable --now libvirtd cockpit.socket 2>/dev/null || true
usermod -aG libvirt "$ACTUAL_USER" 2>/dev/null || true
chmod 775 /var/lib/libvirt/images 2>/dev/null || true
ok "libvirtd and cockpit.socket enabled"

# ── firewalld ────────────────────────────────────────────────────────────────
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --add-service=cockpit --permanent 2>/dev/null || true
firewall-cmd --add-service=dns     --permanent 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true
ok "firewalld: cockpit + dns open"

# ── yq ───────────────────────────────────────────────────────────────────────
section "Phase 0B — yq"
if command -v yq &>/dev/null; then
  ok "yq already installed: $(yq --version 2>&1)"
else
  YQ_VER="v4.45.1"
  info "Installing yq ${YQ_VER}…"
  curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64" \
    -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
  ok "yq installed: $(yq --version 2>&1)"
fi

# ── sushy-tools ───────────────────────────────────────────────────────────────
section "Phase 0C — sushy-tools (Redfish emulator)"
if command -v /usr/local/bin/sushy-emulator &>/dev/null; then
  ok "sushy-emulator already installed"
else
  info "Installing sushy-tools via pip3…"
  pip3 install sushy-tools 2>&1 | tail -3
  ok "sushy-emulator installed"
fi

# ── OCP 4.22 binaries ─────────────────────────────────────────────────────────
section "Phase 0D — OpenShift CLI tools (${OCP_VERSION})"
BIN_DIR="${FRAMEWORK_DIR}/bin"
mkdir -p "$BIN_DIR"

if [[ -f "${BIN_DIR}/openshift-install" ]]; then
  INST_VER=$("${BIN_DIR}/openshift-install" version 2>&1 | head -1)
  ok "openshift-install already in bin/: ${INST_VER}"
else
  info "Downloading openshift-install ${OCP_VERSION}…"
  MIRROR="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}"
  TMP=$(mktemp -d)
  curl -fL "${MIRROR}/openshift-install-linux.tar.gz" -o "${TMP}/install.tar.gz"
  curl -fL "${MIRROR}/openshift-client-linux.tar.gz"  -o "${TMP}/client.tar.gz"
  tar xzf "${TMP}/install.tar.gz" -C "${TMP}"
  tar xzf "${TMP}/client.tar.gz"  -C "${TMP}"
  install -m 755 "${TMP}/openshift-install" "${BIN_DIR}/openshift-install"
  install -m 755 "${TMP}/oc"                "${BIN_DIR}/oc"
  install -m 755 "${TMP}/kubectl"           "${BIN_DIR}/kubectl"
  # Also ensure system-wide copy is up to date
  install -m 755 "${TMP}/openshift-install" /usr/local/bin/openshift-install
  install -m 755 "${TMP}/oc"                /usr/local/bin/oc
  install -m 755 "${TMP}/kubectl"           /usr/local/bin/kubectl
  rm -rf "$TMP"
  chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${BIN_DIR}"
  ok "openshift-install ${OCP_VERSION} → ${BIN_DIR}/ and /usr/local/bin/"
fi

# ── Ansible collections ───────────────────────────────────────────────────────
section "Phase 0E — Ansible collections"
REQ="${FRAMEWORK_DIR}/playbooks/collections/requirements.yml"
if [[ -f "$REQ" ]]; then
  info "Installing collections from ${REQ}…"
  sudo -u "$ACTUAL_USER" ansible-galaxy collection install -r "$REQ" 2>&1 | tail -5
  ok "Ansible collections installed"
else
  warn "requirements.yml not found at ${REQ} — skipping"
fi

# ── Clone framework if missing ────────────────────────────────────────────────
section "Phase 0F — openshift-agent-install framework"
if [[ -d "${FRAMEWORK_DIR}/.git" ]]; then
  ok "Framework already cloned at ${FRAMEWORK_DIR}"
else
  info "Cloning tosin2013/openshift-agent-install…"
  sudo -u "$ACTUAL_USER" git clone \
    https://github.com/tosin2013/openshift-agent-install "${FRAMEWORK_DIR}"
  ok "Framework cloned"
fi

# Sync our two-node-fencing example into the framework
if [[ -d "${SCRIPT_DIR}/../examples/two-node-fencing" ]]; then
  cp -r "${SCRIPT_DIR}/../examples/two-node-fencing" \
        "${FRAMEWORK_DIR}/examples/"
  chown -R "${ACTUAL_USER}:${ACTUAL_USER}" \
        "${FRAMEWORK_DIR}/examples/two-node-fencing"
  ok "two-node-fencing example synced into framework"
fi

# ── SSH key ───────────────────────────────────────────────────────────────────
section "Phase 0G — SSH key pair"
SSH_KEY="${ACTUAL_HOME}/.ssh/openshift-twonode-ed25519"
if [[ -f "${SSH_KEY}" ]]; then
  ok "SSH key already exists: ${SSH_KEY}"
else
  sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -C "openshift-twonode" \
    -f "${SSH_KEY}" -N ""
  ok "SSH key created: ${SSH_KEY}"
fi

# ── Cockpit admin user (needed for VyOS console access) ───────────────────────
section "Phase 0H — Cockpit admin user"
COCKPIT_USER="cockpit-admin"
CREDS_FILE="${ACTUAL_HOME}/cockpit-credentials.txt"

if id "$COCKPIT_USER" &>/dev/null; then
  ok "Cockpit user '${COCKPIT_USER}' already exists"
else
  COCKPIT_PASS=$(openssl rand -base64 16)
  useradd -m -G wheel,libvirt "$COCKPIT_USER"
  echo "${COCKPIT_USER}:${COCKPIT_PASS}" | chpasswd
  cat > "$CREDS_FILE" <<EOFCREDS
============================================
Cockpit Web Console Credentials
============================================
Access URL : https://${HOST_PRIVATE_IP}:9090
             (or https://<YOUR-PUBLIC-IP>:9090 via public IP)

Username   : ${COCKPIT_USER}
Password   : ${COCKPIT_PASS}

Created    : $(date)

⚠  REQUIRED for VyOS router configuration (Phase 2)
   Virtual Machines → vyos-router → Console tab
============================================
EOFCREDS
  chmod 600 "$CREDS_FILE"
  chown "${ACTUAL_USER}:${ACTUAL_USER}" "$CREDS_FILE"
  ok "Cockpit user created — credentials at ${CREDS_FILE}"
fi

# ── Registry authentication ───────────────────────────────────────────────────
section "Phase 0I — Registry auth (~/.docker/config.json)"
DOCKER_DIR="${ACTUAL_HOME}/.docker"
mkdir -p "$DOCKER_DIR" && chmod 700 "$DOCKER_DIR"

PULL_SECRET=""
for candidate in "${ACTUAL_HOME}/pull-secret.json" "${ACTUAL_HOME}/pullsecret.json"; do
  [[ -f "$candidate" ]] && PULL_SECRET="$candidate" && break
done

if [[ -z "$PULL_SECRET" ]]; then
  die "Pull secret not found. Place it at ~/pull-secret.json and re-run."
fi

cp "$PULL_SECRET" "${DOCKER_DIR}/config.json"
chmod 600 "${DOCKER_DIR}/config.json"
chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "$DOCKER_DIR"
ok "Registry auth configured from $(basename ${PULL_SECRET})"

# ── dnsmasq base config (setup-dnsmasq.sh) ────────────────────────────────────
section "Phase 0J — dnsmasq base configuration"
DNSMASQ_CONF="/etc/dnsmasq.d/openshift.conf"

if [[ -f "$DNSMASQ_CONF" ]]; then
  ok "dnsmasq openshift.conf already exists"
else
  info "Running hack/setup-dnsmasq.sh…"
  bash "${FRAMEWORK_DIR}/hack/setup-dnsmasq.sh"
  ok "dnsmasq base config created"
fi

# Ensure dnsmasq listens on host private IP (not just 127.0.0.1)
# so that VyOS can forward cluster DNS queries to it.
if ! grep -q "listen-address=${HOST_PRIVATE_IP}" "$DNSMASQ_CONF" 2>/dev/null; then
  info "Adding listen-address entries to dnsmasq config…"
  # Add IPv4 host IP + IPv6 loopback (::1 needed so dig @localhost works from scripts)
  sed -i "s/^listen-address=127\.0\.0\.1$/listen-address=127.0.0.1\nlisten-address=::1\nlisten-address=${HOST_PRIVATE_IP}/" \
      "$DNSMASQ_CONF"
  # Upstream resolvers (needed since no-resolv is set)
  cat >> "$DNSMASQ_CONF" <<'EOF'

# Upstream resolvers (public DNS — replace with your site-specific resolvers if needed)
server=8.8.8.8
server=1.1.1.1
EOF
  ok "dnsmasq listens on 127.0.0.1, ::1, and ${HOST_PRIVATE_IP}"
fi

systemctl enable --now dnsmasq
ok "dnsmasq enabled and started"

# ── Summary ───────────────────────────────────────────────────────────────────
section "Bootstrap Complete"
echo ""
echo "  OCP binaries  : ${BIN_DIR}/openshift-install ($(${BIN_DIR}/openshift-install version 2>&1 | head -1))"
  echo "  yq            : $(/usr/local/bin/yq --version 2>&1)"
echo "  sushy-emulator: $(/usr/local/bin/sushy-emulator --version 2>&1 | head -1)"
echo "  Cockpit       : https://<YOUR-PUBLIC-IP>:9090 — creds at ${CREDS_FILE}"
echo "  dnsmasq       : $(systemctl is-active dnsmasq) | listening on 127.0.0.1 + ${HOST_PRIVATE_IP}"
echo ""
echo "  NEXT: Phase 1 — add cluster DNS entries"
echo "    cd ${FRAMEWORK_DIR}"
echo "    sudo ./hack/configure-dnsmasq-entries.sh add examples/two-node-fencing/cluster.yml"
echo "    ./hack/verify-dns-resolution.sh examples/two-node-fencing/cluster.yml"
echo ""
