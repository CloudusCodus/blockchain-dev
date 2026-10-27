#!/usr/bin/env bash
# Collects the evidence for the assignment into one snapshot folder,
# evidence/<label>/ (default label: UTC timestamp). Run it once both clients
# are synced. Read-only, changes nothing.
#   scripts/collect-evidence.sh [label]
# Needs: docker, curl, jq
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=evidence/${1:-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"

GETH_RPC=http://127.0.0.1:8545
BEACON_API=http://127.0.0.1:5052
# Public reference nodes to compare our head with
REF_RPC=https://ethereum-sepolia-rpc.publicnode.com
REF_BEACON=https://ethereum-sepolia-beacon-api.publicnode.com

DATA_DIR=./data
[ -f .env ] && DATA_DIR=$(grep -E '^DATA_DIR=' .env | cut -d= -f2-)

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# JSON-RPC call against a geth endpoint: rpc <url> <method> [params]
rpc() {
    curl -s --max-time 10 -X POST -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" "$1"
}
# JavaScript in geth's console over IPC (admin namespace is not exposed over HTTP)
attach() { docker exec geth geth attach --exec "$1" /data/geth.ipc; }
beacon() { curl -s --max-time 10 "$BEACON_API$1"; }
hex2dec() { printf '%d' "$1"; }
cmd() { printf '\n$ %s\n' "$1"; }
header() { printf '# %s\n# collected %s\n' "$1" "$TS"; }

# ---------------------------------------------------------------- execution layer
{
    header "Execution layer (geth)"

    printf '\n## Geth running\n'
    cmd "docker ps --filter name=^geth$"
    docker ps --filter name=^geth$ --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    cmd "web3_clientVersion"
    rpc $GETH_RPC web3_clientVersion | jq -r .result

    printf '\n## Geth synchronized\n'
    cmd "eth_syncing  (false = synced)"
    rpc $GETH_RPC eth_syncing | jq -c .result

    printf '\n## Current block number\n'
    OWN=$(hex2dec "$(rpc $GETH_RPC eth_blockNumber | jq -r .result)")
    REF=$(hex2dec "$(rpc $REF_RPC eth_blockNumber | jq -r .result)")
    cmd "eth_blockNumber (own node vs. public reference $REF_RPC)"
    echo "own node:  $OWN"
    echo "reference: $REF"
    echo "difference: $((REF - OWN)) blocks"
    cmd "latest block of own node"
    rpc $GETH_RPC eth_getBlockByNumber '["latest",false]' \
        | jq -r '.result | "number \(.number) hash \(.hash) timestamp \(.timestamp)"'

    printf '\n## Execution peers\n'
    cmd "net_peerCount"
    hex2dec "$(rpc $GETH_RPC net_peerCount | jq -r .result)"; echo

    printf '\n## Inbound / outbound connectivity\n'
    cmd "admin.peers grouped by direction (IPC)"
    attach 'JSON.stringify({total: admin.peers.length, inbound: admin.peers.filter(function (p) { return p.network.inbound }).length, outbound: admin.peers.filter(function (p) { return !p.network.inbound }).length})'
    cmd "admin.nodeInfo (advertised enode with public IP and port)"
    attach 'admin.nodeInfo.enode'
    attach 'JSON.stringify(admin.nodeInfo.ports)'
    cmd "first 15 peers: client, remote address, inbound"
    attach 'admin.peers.slice(0, 15).map(function (p) { return p.name.split("/").slice(0, 2).join("/") + "  " + p.network.remoteAddress + "  inbound=" + p.network.inbound }).join("\n")'
} > "$OUT/01-execution-layer.txt" 2>&1

# ---------------------------------------------------------------- consensus layer
{
    header "Consensus layer (Lighthouse)"

    printf '\n## Lighthouse running\n'
    cmd "docker ps --filter name=^lighthouse$"
    docker ps --filter name=^lighthouse$ --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    cmd "GET /eth/v1/node/version"
    beacon /eth/v1/node/version | jq -r .data.version
    cmd "GET /eth/v1/node/health  (200 = synced and ready)"
    curl -s -o /dev/null -w 'HTTP %{http_code}\n' "$BEACON_API/eth/v1/node/health"

    printf '\n## Lighthouse synchronized\n'
    cmd "GET /eth/v1/node/syncing"
    beacon /eth/v1/node/syncing | jq .data
    OWN_SLOT=$(beacon /eth/v1/beacon/headers/head | jq -r .data.header.message.slot)
    REF_SLOT=$(curl -s --max-time 10 "$REF_BEACON/eth/v1/beacon/headers/head" | jq -r .data.header.message.slot)
    cmd "head slot (own node vs. public reference $REF_BEACON)"
    echo "own node:  $OWN_SLOT"
    echo "reference: $REF_SLOT"
    echo "difference: $((REF_SLOT - OWN_SLOT)) slots"
    cmd "GET /eth/v1/beacon/states/head/finality_checkpoints"
    beacon /eth/v1/beacon/states/head/finality_checkpoints | jq -c .data

    printf '\n## Consensus peers\n'
    cmd "GET /eth/v1/node/peer_count"
    beacon /eth/v1/node/peer_count | jq .data

    printf '\n## Inbound / outbound connectivity\n'
    cmd "GET /eth/v1/node/peers?state=connected, counted by direction"
    beacon '/eth/v1/node/peers?state=connected' \
        | jq '[.data[].direction] | group_by(.) | map({(.[0]): length}) | add'
    cmd "GET /eth/v1/node/identity (advertised ENR and addresses)"
    beacon /eth/v1/node/identity | jq '.data | {peer_id, enr, p2p_addresses, discovery_addresses}'
    cmd "first 15 connected peers"
    beacon '/eth/v1/node/peers?state=connected' \
        | jq -r '.data[:15][] | "\(.direction)\t\(.last_seen_p2p_address)"'
} > "$OUT/02-consensus-layer.txt" 2>&1

# ---------------------------------------------------------------- infrastructure
{
    header "Infrastructure"

    printf '\n## Docker containers running\n'
    cmd "docker compose ps"
    docker compose ps
    cmd "docker stats --no-stream"
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' geth lighthouse

    printf '\n## Persistent blockchain data\n'
    cmd "docker inspect (mounts)"
    for c in geth lighthouse; do
        docker inspect "$c" --format '{{.Name}}{{range .Mounts}}  {{.Source}} -> {{.Destination}} ({{.Type}}){{end}}'
    done
    cmd "du -sh $DATA_DIR/*"
    du -sh "$DATA_DIR"/* 2>/dev/null || sudo -n du -sh "$DATA_DIR"/*
    cmd "df -h $DATA_DIR"
    df -h "$DATA_DIR"
    echo
    echo "Restart test: see 04-restart-test.txt in the snapshots after a restart (scripts/restart-test.sh)"

    printf '\n## Errors in the logs (last 24 h)\n'
    # Strips color codes; the level is the first of the first few fields that looks like one
    # (geth: "WARN [10-24|...]", Lighthouse: "<timestamp> WARN ...")
    logs() { docker logs --since 24h "$1" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'; }
    for c in geth lighthouse; do
        cmd "docker logs --since 24h $c | count by level"
        logs "$c" | awk '{ for (i = 1; i <= NF && i <= 5; i++)
                if ($i ~ /^(TRACE|DEBUG|DEBG|INFO|WARN|ERROR|ERRO|CRIT|FATAL)$/) { print $i; break } }' \
            | sort | uniq -c
        cmd "docker logs --since 24h $c | grep -E 'CRIT|FATAL|ERROR|ERRO' (last 20)"
        logs "$c" | grep -E '\b(CRIT|FATAL|ERROR|ERRO)\b' | tail -20 | grep . || echo "(none)"
    done
    echo
    echo "All WARN/ERROR/CRIT lines of the last 24 h: logs-warn-error.txt"
} > "$OUT/03-infrastructure.txt" 2>&1

# Every WARN/ERROR/CRIT line of the last 24 h, so each one can be classified.
# The full logs are too large to keep.
for c in geth lighthouse; do
    printf '\n===== %s\n' "$c"
    docker logs --since 24h "$c" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' \
        | grep -E '\b(WARN|ERROR|ERRO|CRIT|FATAL)\b' || echo "(none)"
done > "$OUT/logs-warn-error.txt"

# ---------------------------------------------------------------- networking
{
    header "Networking"

    cmd "ip -br addr (the public addresses sit directly on the server's interface: no NAT by the provider)"
    ip -br addr
    cmd "public IPv4 as seen from the Internet"
    curl -4 -s --max-time 10 https://api.ipify.org; echo
    cmd "docker port geth / lighthouse (published ports: P2P on all interfaces, RPC on 127.0.0.1 only)"
    docker port geth
    docker port lighthouse
    cmd "ss -tulpn (listening sockets of the node)"
    sudo -n ss -tulpn 2>/dev/null | grep -E ':(30303|9000|9001|8545|8551|5052)\b' \
        || ss -tuln | grep -E ':(30303|9000|9001|8545|8551|5052)\b'
    cmd "iptables -t nat -S DOCKER (Docker's own NAT: public port -> container)"
    sudo -n iptables -t nat -S DOCKER 2>&1
    cmd "egress filter: no traffic to private address ranges (scripts/egress-filter.sh)"
    sudo -n iptables -S OUTPUT 2>&1 | grep DROP
    sudo -n iptables -S DOCKER-USER 2>&1 | grep DROP
    echo
    echo "The inbound firewall is the Hetzner Cloud Firewall in front of the server;"
    echo "its rules and an external port test are in 06-external-check.txt."
} > "$OUT/05-networking.txt" 2>&1

# Full peer lists as raw data for the appendix. The geth console prints the
# JSON as a quoted string, so unwrap it first.
attach 'JSON.stringify(admin.peers)' | jq -r '.' | jq '.' > "$OUT/el-peers.json"
beacon '/eth/v1/node/peers?state=connected' | jq '.' > "$OUT/cl-peers.json"

echo "evidence written to $OUT:"
ls -l "$OUT"
