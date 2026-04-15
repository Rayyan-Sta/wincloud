#!/usr/bin/env bash
# lock-port53.sh — Enforce that only pihole-FTL can own / use port 53.
#
# Strategy:
#   1. Kill any non-pihole process currently listening on port 53.
#   2. OUTPUT chain (owner match): only pihole user + root may send
#      packets to port 53 directly (upstream DNS). Everyone else is REJECT-ed,
#      which forces all DNS through Pi-hole's local listener on 127.0.0.1:53.
#   3. PREROUTING nat REDIRECT: all inbound DNS traffic (UDP + TCP :53)
#      is hard-redirected to localhost:53 — so even if something hard-codes
#      8.8.8.8:53, the query still goes to Pi-hole.
#
# Run once at setup, or call again any time you want to re-apply the rules.
set -euo pipefail

echo "[lock-port53] ── Killing foreign listeners on port 53 ──"

for PID in $(lsof -ti UDP:53 -ti TCP:53 2>/dev/null || true); do
    PROC=$(cat /proc/"$PID"/comm 2>/dev/null || echo "unknown")
    if [[ "$PROC" != "pihole-FTL" ]]; then
        echo "  → killing PID $PID ($PROC)"
        kill -9 "$PID" 2>/dev/null || true
    else
        echo "  → sparing PID $PID (pihole-FTL)"
    fi
done

echo "[lock-port53] ── Applying iptables OUTPUT rules ──"

# Flush current OUTPUT rules (only the port-53 ones to avoid clobbering others)
iptables -D OUTPUT -p udp --dport 53 -m owner --uid-owner pihole -j ACCEPT  2>/dev/null || true
iptables -D OUTPUT -p tcp --dport 53 -m owner --uid-owner pihole -j ACCEPT  2>/dev/null || true
iptables -D OUTPUT -p udp --dport 53 -m owner --uid-owner root   -j ACCEPT  2>/dev/null || true
iptables -D OUTPUT -p tcp --dport 53 -m owner --uid-owner root   -j ACCEPT  2>/dev/null || true
iptables -D OUTPUT -p udp --dport 53 -j REJECT 2>/dev/null || true
iptables -D OUTPUT -p tcp --dport 53 -j REJECT 2>/dev/null || true

# pihole user → allowed (upstream DNS lookups from pihole-FTL)
iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner pihole -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner pihole -j ACCEPT

# root → allowed (Tailscale MagicDNS, sysadmin tasks)
iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner root   -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner root   -j ACCEPT

# Everything else → REJECT (forces DNS through Pi-hole at 127.0.0.1:53)
iptables -A OUTPUT -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -p tcp --dport 53 -j REJECT --reject-with tcp-reset

echo "[lock-port53] ── Applying iptables PREROUTING nat redirect ──"

# Remove stale PREROUTING rules first
iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true

# Hard-redirect all inbound DNS to Pi-hole (handles hard-coded upstream IPs)
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53

echo ""
echo "[lock-port53] ✅  Port 53 is Pi-hole-only."
echo "  OUTPUT:     pihole + root can reach :53 outbound; all others REJECT."
echo "  PREROUTING: all inbound DNS redirected to Pi-hole (127.0.0.1:53)."
