#!/usr/bin/env bash
# Phase 0: checks the server before anything is started and writes the
# result to evidence/00-environment.txt. Read-only, changes nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p evidence
OUT=evidence/00-environment.txt

DATA_DIR=./data
[ -f .env ] && DATA_DIR=$(grep -E '^DATA_DIR=' .env | cut -d= -f2-)

section() { printf '\n### %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

{
    echo "# Environment check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    section "OS / kernel"
    (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); uname -srm

    section "CPU / RAM"
    echo "CPU threads: $(nproc)"
    free -h

    section "Disks (ROTA=1 means spinning disk / HDD)"
    lsblk -d -o NAME,ROTA,SIZE,MODEL
    section "Free space where DATA_DIR=$DATA_DIR would live"
    mkdir -p "$DATA_DIR" 2>/dev/null
    df -h "$DATA_DIR"
    AVAIL_GB=$(df -BG --output=avail "$DATA_DIR" | tail -1 | tr -dc '0-9')
    if [ "${AVAIL_GB:-0}" -lt 650 ]; then
        # ~570 GB was measured for history=postprague on a supernode (Oct 2026);
        # postosaka without supernode needs less, but no measured figure exists
        echo "WARNING: only ${AVAIL_GB} GB free, Sepolia postprague+supernode needs ~570 GB; postosaka needs less (unmeasured), watch the growth"
    else
        echo "OK: ${AVAIL_GB} GB free"
    fi

    section "Tools"
    for t in docker curl jq openssl ss; do
        if have "$t"; then echo "$t: ok"; else echo "$t: MISSING"; fi
    done
    have docker && docker version --format 'docker server {{.Server.Version}}' 2>&1
    have docker && docker compose version 2>&1

    section "Local network"
    ip -br addr | grep -v '^lo'
    ip route show default
    ip -6 route show default 2>/dev/null

    section "Public addresses as seen from the Internet"
    PUB4=$(curl -4 -s --max-time 10 https://api.ipify.org || true)
    PUB6=$(curl -6 -s --max-time 10 https://api6.ipify.org || true)
    echo "public IPv4: ${PUB4:-none}"
    echo "public IPv6: ${PUB6:-none}"
    echo "Compare the public IPv4 with the WAN IP shown in the router."
    echo "Different, or a WAN IP in 100.64.0.0/10 -> CGNAT, IPv4 port forwarding will not work."

    section "First hops towards the Internet (100.64.x.x after the router hints at CGNAT)"
    if have tracepath; then tracepath -n -m 4 1.1.1.1 2>&1 | head -8
    elif have traceroute; then traceroute -n -m 4 1.1.1.1 2>&1
    else echo "neither tracepath nor traceroute installed"; fi

    section "Host firewall"
    if have ufw; then sudo -n ufw status verbose 2>&1 || echo "ufw present, run with sudo to see the status"; fi
    if have firewall-cmd; then sudo -n firewall-cmd --list-all 2>&1 || true; fi
    have ufw || have firewall-cmd || echo "no ufw/firewalld found (check nftables/iptables manually)"

    section "Ports already in use (must be free: 30303, 9000, 9001, 8545, 5052)"
    ss -tulpn 2>/dev/null | grep -E ':(30303|9000|9001|8545|8551|5052)\b' || echo "none of them in use"
} 2>&1 | tee "$OUT"

echo
echo "written to $OUT"
