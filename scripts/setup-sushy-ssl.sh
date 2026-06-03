#!/bin/bash
# setup-sushy-ssl.sh — Enable HTTPS on the sushy-emulator Redfish BMC emulator
#
# fence_redfish (used by OpenShift TNF tnf-setup-job) always attempts a TLS
# handshake regardless of the URL scheme.  This script generates a self-signed
# certificate with an IP SAN for the sushy-bmc interface IP (192.168.122.10)
# and reconfigures sushy-emulator to serve HTTPS.
#
# Idempotent — safe to re-run.  Skips cert generation if the existing cert
# is still valid for more than 30 days.
#
# Usage:
#   sudo bash scripts/setup-sushy-ssl.sh
#
# Environment overrides:
#   SUSHY_IP      192.168.122.10
#   SUSHY_PORT    8000
#   CERT_DIR      /etc/sushy
#   CERT_DAYS     3650

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()      { echo -e "${GREEN}✓ $*${NC}"; }
info()    { echo -e "${BLUE}→ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}"; exit 1; }
section() { echo -e "\n${YELLOW}══ $* ══${NC}"; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

SUSHY_IP="${SUSHY_IP:-192.168.122.10}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
CERT_DIR="${CERT_DIR:-/etc/sushy}"
CERT_DAYS="${CERT_DAYS:-3650}"
CERT_FILE="${CERT_DIR}/sushy.crt"
KEY_FILE="${CERT_DIR}/sushy.key"
CONF_FILE="${CERT_DIR}/sushy-emulator.conf"

###############################################################################
# Phase 1 — Generate self-signed certificate with IP SAN
###############################################################################
section "Phase 1 — TLS certificate"

mkdir -p "${CERT_DIR}"

cert_needs_gen=true
if [[ -f "${CERT_FILE}" ]]; then
  expiry=$(openssl x509 -enddate -noout -in "${CERT_FILE}" 2>/dev/null | cut -d= -f2 || echo "unknown")
  if openssl x509 -checkend $((30 * 86400)) -noout -in "${CERT_FILE}" &>/dev/null; then
    ok "Existing cert valid until ${expiry} — skipping generation"
    cert_needs_gen=false
  else
    warn "Existing cert expires soon (${expiry}) — regenerating"
  fi
fi

if [[ "${cert_needs_gen}" == true ]]; then
  info "Generating self-signed cert for IP SAN ${SUSHY_IP} (${CERT_DAYS} days)…"
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "${KEY_FILE}" \
    -out    "${CERT_FILE}" \
    -days   "${CERT_DAYS}" \
    -subj   "/CN=sushy-bmc/O=OpenShift-TNF-KVM/OU=Redfish" \
    -addext "subjectAltName=IP:${SUSHY_IP},IP:127.0.0.1" 2>&1 | grep -v "^writing" || true
  chmod 600 "${KEY_FILE}" "${CERT_FILE}"
  ok "Certificate generated → ${CERT_FILE}"
fi

###############################################################################
# Phase 2 — Reconfigure sushy-emulator to use the certificate
###############################################################################
section "Phase 2 — sushy-emulator configuration"

info "Writing ${CONF_FILE} with SSL cert paths…"
cat > "${CONF_FILE}" << EOF
SUSHY_EMULATOR_LISTEN_IP = '${SUSHY_IP}'
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_SSL_CERT = '${CERT_FILE}'
SUSHY_EMULATOR_SSL_KEY  = '${KEY_FILE}'
SUSHY_EMULATOR_OS_CLOUD = None
SUSHY_EMULATOR_LIBVIRT_URI = 'qemu+unix:///system'
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = True
SUSHY_EMULATOR_INTERFACE_NAME = 'sushy-bmc'
SUSHY_EMULATOR_BOOT_LOADER_MAP = {
    'UEFI': {
        'x86_64': '/usr/share/OVMF/OVMF_CODE.secboot.fd'
    },
    'Legacy': {
        'x86_64': None
    }
}
EOF
ok "Configuration updated with SSL paths"

###############################################################################
# Phase 3 — Restart sushy-emulator with new config
###############################################################################
section "Phase 3 — Restart sushy-emulator"

info "Stopping existing sushy-emulator…"
systemctl stop sushy-emulator.service 2>/dev/null || true
podman rm -f sushy-emulator 2>/dev/null || true
sleep 2

info "Creating sushy-emulator container with TLS config…"
podman create --name sushy-emulator \
  --network=host \
  --privileged \
  -v "${CERT_DIR}":/etc/sushy:Z \
  -v "/var/run/libvirt":/var/run/libvirt:Z \
  quay.io/metal3-io/sushy-tools \
  sushy-emulator -i "${SUSHY_IP}" -p "${SUSHY_PORT}" \
    --config "${CONF_FILE}"

info "Generating systemd service unit…"
podman generate systemd --restart-policy=always --new -n sushy-emulator \
  > /etc/systemd/system/sushy-emulator.service
systemctl daemon-reload
systemctl enable --now sushy-emulator
ok "sushy-emulator restarted with TLS"

###############################################################################
# Phase 4 — Verify HTTPS endpoint
###############################################################################
section "Phase 4 — Verify HTTPS endpoint"

info "Waiting for HTTPS Redfish API to be ready…"
for i in $(seq 1 30); do
  if curl -sk "https://${SUSHY_IP}:${SUSHY_PORT}/redfish/v1/Managers" \
      2>/dev/null | grep -q "ManagerCollection"; then
    ok "HTTPS Redfish API is up at https://${SUSHY_IP}:${SUSHY_PORT}"
    echo ""
    echo "  Registered systems:"
    curl -sk "https://${SUSHY_IP}:${SUSHY_PORT}/redfish/v1/Systems" \
      | python3 -m json.tool 2>/dev/null | grep "@odata.id" | grep -v '"Systems"' || true
    echo ""
    ok "sushy-tools is now serving HTTPS — fence_redfish TLS handshake will succeed"
    echo ""
    echo "  Fencing address format:"
    echo "    redfish-virtualmedia+https://${SUSHY_IP}:${SUSHY_PORT}/redfish/v1/Systems/<UUID>"
    exit 0
  fi
  echo "  waiting… (${i}/30)"
  sleep 2
done

die "Timeout waiting for HTTPS sushy-emulator — check: podman logs sushy-emulator"
