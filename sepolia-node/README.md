# Sepolia testnet node: geth + Lighthouse

> **Status:** prepared, not started yet. Sections marked _TODO_ are filled in on the home server
> from the files in [`evidence/`](evidence/).

A full Ethereum node for the Sepolia testnet, run with Docker Compose on a home server:

- **geth** is the execution layer (EL). It executes transactions and keeps the state.
- **Lighthouse** is the consensus layer (CL). It follows proof of stake and tells geth which block is the head.

## Setup

```
                 Internet (Sepolia P2P)
                   │                 │
         30303 TCP/UDP        9000 TCP/UDP + 9001 UDP (QUIC)
                   │                 │
   ┌───────────────┴──┐   Engine API  ┌──┴─────────────────┐
   │ geth (EL)        │◄──── 8551 ────┤ Lighthouse (CL)    │
   │ snap sync        │   JWT secret  │ checkpoint sync    │
   │ JSON-RPC 8545    │  (Docker net  │ Beacon API 5052    │
   │ → 127.0.0.1 only │   only)       │ → 127.0.0.1 only   │
   └──────┬───────────┘               └────────┬───────────┘
          ▼                                    ▼
     data/geth (bind mount)            data/lighthouse (bind mount)
```

| Component | Image | Key settings |
|---|---|---|
| geth | `ethereum/client-go:v1.17.10` | `--sepolia --syncmode=snap --state.scheme=path --history.chain=postosaka --history.logs.disable` |
| Lighthouse | `sigp/lighthouse:v8.3.2` | `bn --network=sepolia --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io` |

Why these settings:

- **Snap sync** downloads a recent state snapshot instead of re-executing every block since genesis.
- **Path-based state scheme** prunes old state automatically.
- **`--history.chain=postosaka`** keeps block bodies and receipts only from the Osaka fork on (Sepolia block 9,408,577). It is the smallest predefined history mode and keeps the node as small as possible.
- **`--history.logs.disable`** skips the log search index, which a node without dApp users does not need.
- **Checkpoint sync** lets Lighthouse start from a recent finalized state. It is in sync within minutes instead of days.
- **Not a supernode**, and blobs are pruned (Lighthouse default).

### Run it

```sh
cp .env.example .env          # set PUBLIC_IP and DATA_DIR
scripts/preflight.sh          # checks the server -> evidence/00-environment.txt
scripts/gen-jwt.sh            # shared secret for the Engine API
docker compose up -d
docker compose logs -f        # watch the sync
# once synced:
scripts/restart-test.sh       # -> evidence/04-restart-test.txt
scripts/collect-evidence.sh   # -> evidence/01..05
```

## Evidence

_TODO: paste the key lines from each evidence file and add a one-line verdict per row._

### Execution layer ([01-execution-layer.txt](evidence/01-execution-layer.txt))

| Requirement | Evidence | Result |
|---|---|---|
| Geth running | `docker ps`, `web3_clientVersion` | _TODO_ |
| Geth synchronized | `eth_syncing` = `false` | _TODO_ |
| Current block number | `eth_blockNumber` vs. public reference node | _TODO_ |
| Execution peers | `net_peerCount`, `admin.peers` | _TODO_ |
| Inbound/outbound | `admin.peers[].network.inbound` | _TODO_ |

### Consensus layer ([02-consensus-layer.txt](evidence/02-consensus-layer.txt))

| Requirement | Evidence | Result |
|---|---|---|
| Lighthouse running | `docker ps`, `/eth/v1/node/version`, `/eth/v1/node/health` | _TODO_ |
| Lighthouse synchronized | `/eth/v1/node/syncing` (`is_syncing: false`), head slot vs. reference | _TODO_ |
| Consensus peers | `/eth/v1/node/peer_count` | _TODO_ |
| Inbound/outbound | `/eth/v1/node/peers` by `direction` | _TODO_ |

### Infrastructure ([03-infrastructure.txt](evidence/03-infrastructure.txt), [04-restart-test.txt](evidence/04-restart-test.txt))

| Requirement | Evidence | Result |
|---|---|---|
| Docker containers running | `docker compose ps`, `docker stats` | _TODO_ |
| Persistent blockchain data | bind mounts, `du -sh`, restart test continues from the same block | _TODO_ |
| No critical errors in logs | log levels counted over 24 h, every ERROR/CRIT line classified | _TODO_ |

## Networking

### NAT / firewall situation

_TODO: fill in from evidence/00-environment.txt and 05-networking.txt._

- Internet connection: _ISP, public IPv4 (static/dynamic), CGNAT/DS-Lite yes/no, IPv6_
- Router: NAT from the public IP to the LAN; port forwards for the P2P ports to the server's fixed LAN IP
- Host firewall: _ufw/nftables rules_, only the P2P ports allowed inbound
- Docker: publishes the P2P ports on all interfaces and the RPC ports on 127.0.0.1 only. Both clients advertise the public IP (`--nat extip:` for geth, `--enr-address` for Lighthouse), because inside the container they only see their Docker-internal IP.

```
Internet ── public IP ──► Router (NAT + port forwarding) ──► Server LAN IP ──► Docker (port publishing) ──► container
                          30303 tcp/udp, 9000 tcp/udp,        host firewall
                          9001 udp
```

Without inbound reachability the node still works: it opens connections to other peers itself (outbound). But it never receives connections, so it has fewer and less diverse peers, and it does not help other nodes. Inbound peers in the evidence prove that the forwarding works.

### Required P2P ports

| Port | Protocol | Client | Purpose | Forwarded |
|---|---|---|---|---|
| 30303 | TCP | geth | devp2p / RLPx: block and transaction exchange with other execution clients | yes |
| 30303 | UDP | geth | discovery (discv4/discv5): finding other execution nodes | yes |
| 9000 | TCP | Lighthouse | libp2p: gossip and requests between consensus clients | yes |
| 9000 | UDP | Lighthouse | discv5: finding other consensus nodes | yes |
| 9001 | UDP | Lighthouse | libp2p over QUIC | yes |
| 8545 | TCP | geth | JSON-RPC (user API) | **no**, 127.0.0.1 only |
| 8551 | TCP | geth | Engine API (EL ↔ CL), JWT-authenticated | **no**, Docker network only |
| 5052 | TCP | Lighthouse | Beacon API | **no**, 127.0.0.1 only |

### Why RPC ports must not simply be exposed to the Internet

The P2P ports speak protocols that are designed for untrusted peers: every message is validated, peers are scored, and misbehaving ones are disconnected. The RPC ports are different. They are interfaces for the **operator**, without any authentication (8545, 5052) or with a single shared secret (8551).

1. **No authentication, no rate limiting.** Anyone who finds the port can use the node. Bots scan the whole IPv4 space for open 8545 ports within hours.
2. **Denial of service.** Calls like `eth_call`, `eth_estimateGas`, `eth_getLogs` over large ranges, or `debug_trace*` cost a lot of CPU, memory and disk I/O. A few parallel requests can slow the node down until it falls behind the chain.
3. **Dangerous namespaces.** If `admin`, `debug`, `personal`, `miner` or `txpool` are enabled, an attacker can add or remove peers (eclipse attack), read internal data, or stop parts of the node. On nodes with unlocked accounts, attackers have stolen funds this way ("Ethereum black valentine" attacks on open 8545 ports).
4. **The Engine API controls the execution layer.** Whoever can talk to 8551 decides which chain geth follows (`engine_forkchoiceUpdated`, `engine_newPayload`). It is protected only by the JWT secret, and it was never meant to be reachable from outside the machine.
5. **Information leaks.** The Beacon and JSON-RPC APIs reveal the client version, peers, sync state and, with validators, validator identities. This helps targeted attacks and deanonymisation.

Better options when remote access is needed:

- keep the ports on localhost and use an **SSH tunnel** or a **VPN** (WireGuard, Tailscale)
- or put a **reverse proxy** in front with authentication, TLS, rate limiting and an allowlist of read-only methods
- never expose `admin`/`debug`/`engine` methods

## Resource usage

_TODO: disk usage of geth and Lighthouse after the sync, RAM, sync duration._

## Lessons learned

_TODO_
