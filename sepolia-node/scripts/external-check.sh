#!/usr/bin/env bash
# Runs OUTSIDE the node (e.g. on the admin machine) and shows what the
# Internet sees: the Hetzner Cloud Firewall rules (read via the API) and which
# ports of the node answer. P2P must be reachable, RPC must not.
#   scripts/external-check.sh <node-ip> <label>   writes evidence/<label>/06-external-check.txt
# Needs: curl, jq, a read token in ~/.config/hcloud/token
set -uo pipefail
cd "$(dirname "$0")/.."
NODE=${1:?usage: $0 <node-ip> <label>}
OUT=evidence/${2:?usage: $0 <node-ip> <label>}
mkdir -p "$OUT"

api() {
    curl -s --max-time 15 -H "Authorization: Bearer $(tr -d '\n\r ' < ~/.config/hcloud/token)" \
        "https://api.hetzner.cloud/v1/$1"
}
cmd() { printf '\n$ %s\n' "$1"; }

{
    echo "# External check from a host outside Hetzner, $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # The SSH rule's source is the admin's own address, which stays private
    cmd "Hetzner Cloud Firewall rules of the node (GET /v1/firewalls, admin address masked)"
    api firewalls | jq -r '
        .firewalls[] | "firewall \(.name)",
        (.rules[] | "  \(.direction) \(.protocol) \(.port // "-")  from \(
            if .port == "22" then "<admin IPv4>/32" else (.source_ips | join(", ")) end)")'
    echo "Everything not listed is dropped inbound. Outbound has no rules, so it is allowed."

    cmd "TCP connect test against $NODE (expected: P2P open, RPC closed)"
    for p in 30303 9000 8545 8551 5052; do
        case $p in 30303|9000) want=open ;; *) want=closed ;; esac
        if timeout 5 bash -c "</dev/tcp/$NODE/$p" 2>/dev/null; then got=open; else got=closed; fi
        printf '%-6s %-7s expected %-7s %s\n' "$p/tcp" "$got" "$want" "$([ "$got" = "$want" ] && echo OK || echo UNEXPECTED)"
    done
    echo "(UDP 30303/9000/9001 cannot be tested with a plain connect; the inbound peers in"
    echo " 01-execution-layer.txt and 02-consensus-layer.txt show that they are reachable.)"
} 2>&1 | tee "$OUT/06-external-check.txt"
