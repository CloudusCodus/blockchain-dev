#!/usr/bin/env bash
# Prints the sync state of both clients. Exit 0 when both are synced, 1 otherwise.
# Needs: curl, jq
set -uo pipefail

GETH_RPC=http://127.0.0.1:8545
BEACON_API=http://127.0.0.1:5052

rpc() {
    curl -s --max-time 5 -X POST -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":[]}" "$GETH_RPC"
}

# geth: eth_syncing is the boolean false only when synced, otherwise an object
EL=$(rpc eth_syncing | jq -c '.result')
BLOCK=$(rpc eth_blockNumber | jq -r '.result // "0x0"')
PEERS=$(rpc net_peerCount | jq -r '.result // "0x0"')
echo "geth:       syncing=$EL"
echo "            block=$(printf '%d' "$BLOCK") peers=$(printf '%d' "$PEERS")"

# Lighthouse: synced and the head verified by geth (not optimistic)
CL=$(curl -s --max-time 5 "$BEACON_API/eth/v1/node/syncing" | jq -c '.data')
echo "lighthouse: $CL"

if [ "$EL" = "false" ] && [ "$(jq -r '.is_syncing == false and .is_optimistic == false and .el_offline == false' <<<"$CL")" = "true" ]; then
    echo "SYNCED"
    exit 0
fi
echo "NOT SYNCED"
exit 1
