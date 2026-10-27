#!/usr/bin/env bash
# Drops traffic from the server (and its containers) to private and shared
# address ranges on the public interface. P2P clients sometimes dial such
# addresses learned from other peers; on a hosting network that looks like a
# network scan and can trigger abuse reports. Safe to run more than once.
set -euo pipefail

IFACE=${1:-eth0}
RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"
# The default gateway can itself sit in a private range (Hetzner Cloud:
# 172.31.1.1) and must stay reachable, e.g. for DHCP lease renewals
GATEWAY=$(ip -4 route show default dev "$IFACE" | awk '{ print $3; exit }')

# OUTPUT covers the host itself, DOCKER-USER the containers (forwarded traffic)
for chain in OUTPUT DOCKER-USER; do
    iptables -n -L "$chain" >/dev/null 2>&1 || continue
    for r in $RANGES; do
        iptables -C "$chain" -o "$IFACE" -d "$r" -j DROP 2>/dev/null \
            || iptables -I "$chain" -o "$IFACE" -d "$r" -j DROP
    done
done
# Inserted last, so it sits above the DROP rules
if [ -n "$GATEWAY" ]; then
    iptables -C OUTPUT -o "$IFACE" -d "$GATEWAY" -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT -o "$IFACE" -d "$GATEWAY" -j ACCEPT
fi
echo "egress filter active on $IFACE for $RANGES (gateway ${GATEWAY:-none} allowed)"
