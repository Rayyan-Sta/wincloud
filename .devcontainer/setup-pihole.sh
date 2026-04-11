#!/usr/bin/env bash
set -euo pipefail

PIHOLE_PASSWORD="${PIHOLE_WEB_PASSWORD:-wtf123}"
RAM_LIMIT_MB=150
RAM_LIMIT_BYTES=$(( RAM_LIMIT_MB * 1024 * 1024 ))

# ── 1. Pre-configure Pi-hole ──────────────────────────────────────
echo "==> Configuring Pi-hole..."
sudo mkdir -p /etc/pihole
sudo tee /etc/pihole/setupVars.conf > /dev/null <<CONF
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0/0
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNSMASQ_LISTENING=all
BLOCKING_ENABLED=true
PIHOLE_DNS_1=8.8.8.8
PIHOLE_DNS_2=8.8.4.4
WEBPASSWORD=$(echo -n "${PIHOLE_PASSWORD}" | sha256sum | awk '{print $1}' | sha256sum | awk '{print $1}')
CONF

# ── 2. Install Pi-hole ────────────────────────────────────────────
echo "==> Installing Pi-hole..."
curl -sSL https://install.pi-hole.net | sudo bash /dev/stdin --unattended

# ── 3. RAM limit via cgroup ───────────────────────────────────────
echo "==> Applying ${RAM_LIMIT_MB}MB RAM limit to pihole-FTL..."
if [[ -d /sys/fs/cgroup/memory ]]; then
  sudo cgcreate -g memory:pihole 2>/dev/null || true
  echo "${RAM_LIMIT_BYTES}" | sudo tee /sys/fs/cgroup/memory/pihole/memory.limit_in_bytes > /dev/null
  echo "0"                  | sudo tee /sys/fs/cgroup/memory/pihole/memory.swappiness      > /dev/null
else
  sudo mkdir -p /sys/fs/cgroup/pihole
  echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control > /dev/null 2>&1 || true
  echo "${RAM_LIMIT_BYTES}" | sudo tee /sys/fs/cgroup/pihole/memory.max      > /dev/null
  echo "0"                  | sudo tee /sys/fs/cgroup/pihole/memory.swap.max > /dev/null
fi

# Move pihole-FTL into the cgroup
for pid in $(pgrep -x pihole-FTL 2>/dev/null); do
  if [[ -d /sys/fs/cgroup/memory ]]; then
    echo "$pid" | sudo tee /sys/fs/cgroup/memory/pihole/cgroup.procs > /dev/null
  else
    echo "$pid" | sudo tee /sys/fs/cgroup/pihole/cgroup.procs > /dev/null
  fi
  echo "  Assigned PID $pid to cgroup"
done

# ── 4. Lock port 53 to Pi-hole only ──────────────────────────────
echo "==> Locking port 53 to Pi-hole..."
PIHOLE_UID=$(id -u pihole 2>/dev/null || echo 999)

# Allow Pi-hole to use port 53
sudo iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner "$PIHOLE_UID" -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "$PIHOLE_UID" -j ACCEPT
sudo iptables -A OUTPUT -p udp --sport 53 -m owner --uid-owner "$PIHOLE_UID" -j ACCEPT
sudo iptables -A OUTPUT -p tcp --sport 53 -m owner --uid-owner "$PIHOLE_UID" -j ACCEPT
# Block everyone else from port 53
sudo iptables -A OUTPUT -p udp --dport 53 -j REJECT
sudo iptables -A OUTPUT -p tcp --dport 53 -j REJECT

echo ""
echo "✅ Pi-hole ready → http://localhost/admin"
echo "   RAM cap: ${RAM_LIMIT_MB}MB | Port 53 locked to pihole user"
