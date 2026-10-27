#!/usr/bin/env bash
# Shows that the chain data survives the containers: removes them with
# `docker compose down`, creates them again with `up -d`, and records block and
# slot before and after. The node continues from where it was instead of
# syncing from scratch. Run only when both clients are synced.
#   scripts/restart-test.sh <label>   writes evidence/<label>/04-restart-test.txt
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=evidence/${1:?usage: $0 <label>}
mkdir -p "$OUT"

block() {
    curl -s --max-time 5 -X POST -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        http://127.0.0.1:8545 | jq -r '.result // empty' | xargs -r printf '%d'
}
slot() { curl -s --max-time 5 http://127.0.0.1:5052/eth/v1/beacon/headers/head | jq -r '.data.header.message.slot // empty'; }
syncing() { curl -s --max-time 5 http://127.0.0.1:5052/eth/v1/node/syncing | jq -c '.data // empty'; }
ids() { docker compose ps -q | cut -c1-12 | tr '\n' ' '; }
now() { date -u +%H:%M:%SZ; }

{
    echo "# Restart test, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Before"
    echo "$(now)  geth block $(block)  lighthouse slot $(slot)"
    echo "container IDs: $(ids)"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}'

    echo
    echo "## docker compose down  (containers are removed, only the data on the volume stays)"
    docker compose down
    echo "containers left: $(docker compose ps -aq | wc -l)"

    echo
    echo "## docker compose up -d  (new containers)"
    docker compose up -d

    echo
    echo "## After (waiting for the APIs to come back)"
    for _ in $(seq 1 60); do
        B=$(block); S=$(slot)
        [ -n "$B" ] && [ -n "$S" ] && break
        sleep 5
    done
    echo "$(now)  geth block $B  lighthouse slot $S"
    echo "container IDs: $(ids)"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}'
    echo "lighthouse syncing: $(syncing)"
} 2>&1 | tee "$OUT/04-restart-test.txt"
