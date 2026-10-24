#!/usr/bin/env bash
# Shows that the chain data survives a container restart: the node continues
# from the block it had before instead of syncing from scratch.
# Run only when both clients are synced.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p evidence
OUT=evidence/04-restart-test.txt

block() {
    curl -s --max-time 5 -X POST -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        http://127.0.0.1:8545 | jq -r '.result // empty' | xargs -r printf '%d'
}
slot() { curl -s --max-time 5 http://127.0.0.1:5052/eth/v1/beacon/headers/head | jq -r '.data.header.message.slot // empty'; }
syncing() { curl -s --max-time 5 http://127.0.0.1:5052/eth/v1/node/syncing | jq -c '.data // empty'; }
now() { date -u +%H:%M:%SZ; }

{
    echo "# Restart test, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Before restart"
    echo "$(now)  geth block $(block)  lighthouse slot $(slot)"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}'

    echo
    echo "## docker compose restart"
    docker compose restart

    echo
    echo "## After restart (waiting for the APIs to come back)"
    for _ in $(seq 1 60); do
        B=$(block); S=$(slot)
        [ -n "$B" ] && [ -n "$S" ] && break
        sleep 5
    done
    echo "$(now)  geth block $B  lighthouse slot $S"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}'

    echo
    echo "## Two minutes later (node keeps following the chain)"
    sleep 120
    echo "$(now)  geth block $(block)  lighthouse slot $(slot)"
    echo "lighthouse syncing: $(syncing)"
} 2>&1 | tee "$OUT"
