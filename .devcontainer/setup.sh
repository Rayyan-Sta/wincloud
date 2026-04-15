#!/usr/bin/env bash
# setup.sh — Runs once at postCreateCommand
# Installs: QEMU/KVM + OVMF + swtpm + Pi-hole, then locks port 53
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Packages ───────────────────────────────────────────────────────────────

curl -fsSL https://tailscale.com/install.sh | sh
echo "  → Tailscale installed: $(tailscale version 2>/dev/null || tailscaled --version)"
echo "  → Run 'tailscale up' after the container starts to authenticate."
echo "━━━ [1/5] Installing packages ━━━"

apt-get update -y
apt-get install -y --no-install-recommends \
    qemu-system-x86 \
    qemu-utils \
    ovmf \
    swtpm \
    swtpm-tools \
    iptables \
    iproute2 \
    net-tools \
    curl \
    ca-certificates \
    git \
    lsof \
    psmisc

# ── 2. Free port 53 from systemd-resolved ─────────────────────────────────────
echo "━━━ [2/5] Disabling systemd-resolved (frees port 53) ━━━"
systemctl disable --now systemd-resolved 2>/dev/null || true

# Write a static resolv.conf so DNS still works during Pi-hole install,
# then lock it immutable so nothing (NetworkManager, resolvconf) overwrites it.
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'RESOLVEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLVEOF
chattr +i /etc/resolv.conf
echo "  → /etc/resolv.conf locked to 8.8.8.8 / 1.1.1.1"

# ── 3. Pi-hole unattended install ─────────────────────────────────────────────
echo "━━━ [3/5] Installing Pi-hole (unattended) ━━━"
export PIHOLE_SKIP_OS_CHECK=true
mkdir -p /etc/pihole

# Pre-seed answers for the interactive installer
cat > /etc/pihole/setupVars.conf <<'PVEOF'
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0/0
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=false
BLOCKING_ENABLED=true
WEBPASSWORD=
DNSMASQ_LISTENING=all
DNS1=8.8.8.8
DNS2=1.1.1.1
PIHOLE_DNS_1=8.8.8.8
PIHOLE_DNS_2=1.1.1.1
PVEOF

curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
echo "  → Pi-hole installed. Admin UI: http://localhost/admin"

# ── 4. Lock port 53 to Pi-hole only ──────────────────────────────────────────
echo "━━━ [4/5] Locking port 53 to Pi-hole ━━━"
bash "$SCRIPT_DIR/lock-port53.sh"

# ── 5. Verify QEMU / OVMF / swtpm ────────────────────────────────────────────
echo "━━━ [5/5] Verifying QEMU stack ━━━"

QEMU_VER=$(qemu-system-x86_64 --version | head -1)
echo "  QEMU:  $QEMU_VER"

OVMF_PATH=/usr/share/OVMF/OVMF_CODE.fd
if [[ -f "$OVMF_PATH" ]]; then
    echo "  OVMF:  $OVMF_PATH ✓"
else
    # Some Ubuntu releases put it under a different path
    OVMF_PATH=$(find /usr/share -name "OVMF_CODE*.fd" 2>/dev/null | head -1 || echo "NOT FOUND")
    echo "  OVMF:  $OVMF_PATH"
fi

SWTPM_VER=$(swtpm --version 2>&1 | head -1)
echo "  swtpm: $SWTPM_VER ✓"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  devcontainer setup complete                      ║"
echo "║                                                      ║"
echo "║  Pi-hole admin  →  http://localhost/admin            ║"
echo "║  OVMF firmware  →  $OVMF_PATH"
echo "║  swtpm binary   →  $(which swtpm)"
echo "║  QEMU binary    →  $(which qemu-system-x86_64)"
echo "╚══════════════════════════════════════════════════════╝"