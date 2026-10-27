# Sepolia testnet node: geth + Lighthouse

A full Ethereum node for the **Sepolia** testnet, run with Docker Compose on a Hetzner Cloud server:

- **geth** is the execution layer (EL). It executes the transactions and keeps the state.
- **Lighthouse** is the consensus layer (CL). It follows proof of stake and tells geth which block is the head.

The node only follows the chain. It has no validator and no wallet.

## Result

| Area | Requirement | Result | Evidence |
|---|---|---|---|
| Execution layer | Geth running | ✅ `Geth/v1.17.10-stable`, container up 44 h before the restart test | [01](evidence/4-final/01-execution-layer.txt) |
| | Geth synchronized | ✅ `eth_syncing` = `false`, Lighthouse head verified (`is_optimistic: false`) | [01](evidence/4-final/01-execution-layer.txt) |
| | Current block number | ✅ **12,003,462**, public reference node: 12,003,462 (difference 0) | [01](evidence/4-final/01-execution-layer.txt) |
| | Execution peers | ✅ 29 (50 before the restart test) | [01](evidence/4-final/01-execution-layer.txt) |
| | Inbound/outbound | ✅ 27 inbound / 2 outbound (34 / 16 before the restart test) | [01](evidence/4-final/01-execution-layer.txt) |
| Consensus layer | Lighthouse running | ✅ `Lighthouse/v8.3.2`, `/node/health` = HTTP 200 | [02](evidence/4-final/02-consensus-layer.txt) |
| | Lighthouse synchronized | ✅ `is_syncing: false`, head slot **11,445,877** = reference (difference 0) | [02](evidence/4-final/02-consensus-layer.txt) |
| | Consensus peers | ✅ 77 connected (100 before the restart test) | [02](evidence/4-final/02-consensus-layer.txt) |
| | Inbound/outbound | ✅ 56 inbound / 21 outbound (79 / 21 before the restart test) | [02](evidence/4-final/02-consensus-layer.txt) |
| Infrastructure | Docker containers running | ✅ both containers up | [03](evidence/1-before-restart/03-infrastructure.txt) |
| | Persistent blockchain data | ✅ containers removed and recreated twice, the node continued from the same block | [04](evidence/2-after-restart-1/04-restart-test.txt), [04](evidence/3-after-restart-2/04-restart-test.txt) |
| | No critical errors in logs | ⚠️ geth: no errors. Lighthouse: one 6-minute Engine API timeout with 1 CRIT that recovered on its own, plus 8 errors about serving data to peers. Details [below](#no-critical-errors-in-logs) | [03](evidence/1-before-restart/03-infrastructure.txt), [log lines](evidence/1-before-restart/logs-warn-error.txt) |
| Networking | NAT/firewall situation | ✅ [explained below](#natfirewall-situation) | [05](evidence/4-final/05-networking.txt), [06](evidence/4-final/06-external-check.txt) |
| | Required P2P ports | ✅ [table below](#required-p2p-ports) | [05](evidence/4-final/05-networking.txt) |
| | Why RPC ports must not be exposed | ✅ [explained below](#why-rpc-ports-must-not-simply-be-exposed-to-the-internet), external test: 8545/8551/5052 closed | [06](evidence/4-final/06-external-check.txt) |

The numbers in this table come from the main snapshot `4-final`, taken six minutes after the second restart. The other snapshots are listed in [Evidence snapshots](#evidence-snapshots).

## Setup

```
                 Internet (Sepolia P2P)
                   │                 │
         30303 TCP/UDP        9000 TCP/UDP + 9001 UDP (QUIC)
                   │                 │
            Hetzner Cloud Firewall (stateful, inbound allow-list)
                   │                 │
   ┌───────────────┴──┐   Engine API  ┌──┴─────────────────┐
   │ geth (EL)        │◄──── 8551 ────┤ Lighthouse (CL)    │
   │ snap sync        │   JWT secret  │ checkpoint sync    │
   │ JSON-RPC 8545    │  (Docker net  │ Beacon API 5052    │
   │ → 127.0.0.1 only │   only)       │ → 127.0.0.1 only   │
   └──────┬───────────┘               └────────┬───────────┘
          ▼                                    ▼
   /srv/sepolia/data/geth            /srv/sepolia/data/lighthouse
          └──────────── 1.5 TB Hetzner volume ───┘
```

### Server

| | |
|---|---|
| Provider | Hetzner Cloud, location `fsn1` (Falkenstein) |
| Server type | `cpx42`: 8 vCPU, 16 GB RAM, 320 GB system disk |
| OS | Ubuntu 24.04 LTS, Docker 29.1.3, Docker Compose 2.40.3 |
| Chain data | separate 1.5 TB Hetzner volume (ext4), mounted at `/srv/sepolia/data` |
| Public addresses | `138.201.155.69`, `2a01:4f8:c17:4c0c::1` (directly on `eth0`) |
| Runtime | 2026-10-25 11:10 UTC to 2026-10-27 ~07:00 UTC (about 44 h), then deleted |

The server, the volume and the firewall were created in the Hetzner Cloud Console. On first boot, [`terraform/cloud-init.yaml`](terraform/cloud-init.yaml) installs Docker, mounts the volume, writes the node files to `/srv/sepolia`, puts the public IP into `.env`, creates the JWT secret, enables the egress filter and starts the node. A systemd drop-in lets Docker start only after the volume is mounted, so the node can never write chain data to the small system disk. The same template is used by [`terraform/main.tf`](terraform/main.tf), which describes the whole setup as code.

### Clients and settings

| Component | Image | Key settings |
|---|---|---|
| geth | `ethereum/client-go:v1.17.10` | `--sepolia --syncmode=snap --state.scheme=path --history.chain=postosaka --history.logs.disable` |
| Lighthouse | `sigp/lighthouse:v8.3.2` | `bn --network=sepolia --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io` |

Both image versions are pinned (no `latest`). They were the latest stable releases when the node was set up.

Why these settings:

- **Snap sync** downloads a recent state snapshot instead of re-executing every block since genesis. Sepolia has had the Amsterdam fork active since 2026-10-06, so geth automatically used the new **snap/2** protocol (EIP-8189).
- **Path-based state scheme** prunes old state automatically.
- **`--history.chain=postosaka`** keeps block bodies and receipts only from the Osaka fork on (Sepolia block 9,408,577). It is the smallest predefined history mode.
- **`--history.logs.disable`** skips the log search index, which a node without dApp users does not need.
- **Checkpoint sync** lets Lighthouse start from a recent finalized state. It followed the head within minutes.
- **No supernode, no validator.** Blobs are pruned (Lighthouse default).
- **RPC only for the operator:** geth's HTTP API offers only `eth`, `net` and `web3`. The `admin` namespace is used through IPC inside the container (`geth attach /data/geth.ipc`), never over HTTP.
- **Restart policy and logs:** `restart: unless-stopped`, json-file logs limited to 10 × 50 MB per container, and a 5-minute stop grace period so geth can flush its state.

### Files

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | geth + Lighthouse |
| [`.env.example`](.env.example) | versions, data directory, public IP, history mode |
| [`terraform/`](terraform/) | cloud-init for the first boot, plus the setup as Terraform code |
| [`scripts/gen-jwt.sh`](scripts/gen-jwt.sh) | creates the JWT secret for the Engine API |
| [`scripts/egress-filter.sh`](scripts/egress-filter.sh) | drops outgoing traffic to private address ranges |
| [`scripts/preflight.sh`](scripts/preflight.sh) | server check → `evidence/00-environment.txt` |
| [`scripts/check-sync.sh`](scripts/check-sync.sh) | exit 0 when both clients are synced |
| [`scripts/collect-evidence.sh`](scripts/collect-evidence.sh) | one evidence snapshot → `evidence/<label>/` |
| [`scripts/restart-test.sh`](scripts/restart-test.sh) | `docker compose down` + `up -d`, block before and after |
| [`scripts/external-check.sh`](scripts/external-check.sh) | runs outside the node: cloud firewall rules and port test |

## Evidence snapshots

All evidence is command output, collected by the scripts above on 2026-10-27.

| Snapshot | Time (UTC) | Situation | Block diff to reference | geth in / out | Lighthouse in / out |
|---|---|---|---|---|---|
| [`1-before-restart`](evidence/1-before-restart/) | 06:47 | containers up 44 h | 0 blocks / 0 slots | 34 / 16 | 79 / 21 |
| [`2-after-restart-1`](evidence/2-after-restart-1/) | 06:48 | ~1 min after the 1st `down` + `up` | 1 block / 0 slots | 18 / 2 | 7 / 5 |
| [`3-after-restart-2`](evidence/3-after-restart-2/) | 06:50 | ~1 min after the 2nd `down` + `up` | 7 blocks / 7 slots | 5 / 1 | 9 / 3 |
| [`4-final`](evidence/4-final/) | 06:55 | ~6 min after the 2nd restart (**main evidence**) | 0 blocks / 0 slots | 27 / 2 | 56 / 21 |

[`evidence/00-environment.txt`](evidence/00-environment.txt) is the server check from the first boot. Each snapshot folder contains `01-execution-layer.txt`, `02-consensus-layer.txt`, `03-infrastructure.txt`, `05-networking.txt`, the full peer lists (`el-peers.json`, `cl-peers.json`) and all WARN/ERROR lines (`logs-warn-error.txt`). The snapshots after a restart also contain `04-restart-test.txt`, and `4-final` contains `06-external-check.txt`.

## Execution layer

### Geth running

```
$ docker ps --filter name=^geth$
NAMES     IMAGE                         STATUS
geth      ethereum/client-go:v1.17.10   Up 6 minutes        (4-final; before the restart test: Up 44 hours)

$ web3_clientVersion
Geth/v1.17.10-stable-1df30b18/linux-amd64/go1.27.3
```

### Geth synchronized

```
$ eth_syncing  (false = synced)
false
```

`eth_syncing` alone is not enough: geth also returns `false` right after the first start, before the sync has begun (block 0). That is why the head is also compared with a public node below, and why `scripts/check-sync.sh` only reports `SYNCED` when Lighthouse sees the head as verified by geth (`is_optimistic: false`, `el_offline: false`).

### Current block number

```
$ eth_blockNumber (own node vs. public reference https://ethereum-sepolia-rpc.publicnode.com)
own node:  12003462
reference: 12003462
difference: 0 blocks

$ latest block of own node
number 0xb72886 hash 0x1f01dc4bd25cf85ef697feb9652ce1a7c146e135f120314b284560cf3d5e2530 timestamp 0x6ae04adc
```

### Execution peers and inbound/outbound connectivity

```
$ net_peerCount
29

$ admin.peers grouped by direction (IPC)
{"total":29,"inbound":27,"outbound":2}

$ admin.nodeInfo (advertised enode with public IP and port)
enode://25868022…d633@138.201.155.69:30303
{"discovery":30303,"listener":30303}
```

The node advertises its public IP and port, and most peers connect **inbound**, so other nodes can reach it from the Internet. Before the restart test, after 44 h of uptime, geth had 50 peers (34 inbound, 16 outbound). The peers run different clients (Geth, Nethermind, reth, see `el-peers.json`).

## Consensus layer

### Lighthouse running

```
$ docker ps --filter name=^lighthouse$
NAMES        IMAGE                    STATUS
lighthouse   sigp/lighthouse:v8.3.2   Up 6 minutes

$ GET /eth/v1/node/version
Lighthouse/v8.3.2/x86_64-linux

$ GET /eth/v1/node/health  (200 = synced and ready)
HTTP 200
```

### Lighthouse synchronized

```
$ GET /eth/v1/node/syncing
{
  "is_syncing": false,
  "is_optimistic": false,
  "el_offline": false,
  "head_slot": "11445877",
  "sync_distance": "0"
}

$ head slot (own node vs. public reference https://ethereum-sepolia-beacon-api.publicnode.com)
own node:  11445877
reference: 11445877
difference: 0 slots
```

`is_optimistic: false` means geth has verified the execution payload of the head, so both layers are in sync with each other. `el_offline: false` means the Engine API connection to geth works.

### Consensus peers and inbound/outbound connectivity

```
$ GET /eth/v1/node/peer_count
{ "connected": "77", "connecting": "0", "disconnected": "46", "disconnecting": "0" }

$ GET /eth/v1/node/peers?state=connected, counted by direction
{ "inbound": 56, "outbound": 21 }

$ GET /eth/v1/node/identity (advertised ENR and addresses)
"p2p_addresses":       [ "/ip4/138.201.155.69/tcp/9000/p2p/16Uiu2HAkvF92…" ]
"discovery_addresses": [ "/ip4/138.201.155.69/udp/9000/p2p/16Uiu2HAkvF92…" ]
```

Most inbound consensus peers connect over **QUIC (UDP 9001)**, the others over TCP 9000 (see `cl-peers.json`). Before the restart test Lighthouse had 100 peers, its target (79 inbound, 21 outbound).

## Infrastructure

### Docker containers running

```
$ docker compose ps        (1-before-restart)
NAME         IMAGE                         SERVICE      CREATED        STATUS
geth         ethereum/client-go:v1.17.10   geth         44 hours ago   Up 44 hours
lighthouse   sigp/lighthouse:v8.3.2        lighthouse   44 hours ago   Up 44 hours

$ docker stats --no-stream
NAME         CPU %     MEM USAGE / LIMIT     NET I/O          BLOCK I/O
geth         20.08%    7.984GiB / 15.24GiB   291GB / 71.4GB   843GB / 1.97TB
lighthouse   18.74%    1.448GiB / 15.24GiB   96GB / 61.4GB    68.2GB / 316GB
```

### Persistent blockchain data

The chain data is not stored in the containers. It is bind-mounted from the Hetzner volume:

```
$ docker inspect (mounts)
/geth        /srv/sepolia/data/geth -> /data (bind)        /srv/sepolia/jwt -> /jwt (bind)
/lighthouse  /srv/sepolia/data/lighthouse -> /data (bind)  /srv/sepolia/jwt -> /jwt (bind)

$ du -sh ./data/*
405G	./data/geth
17G	./data/lighthouse

$ df -h ./data
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb        1.5T  421G  980G  31% /srv/sepolia/data
```

**Restart test.** `scripts/restart-test.sh` removes both containers with `docker compose down` and creates new ones with `docker compose up -d`. This was done twice. The container IDs change, but the node continues from the block it had, instead of syncing ~400 GB again:

| | 1st restart | 2nd restart |
|---|---|---|
| Before | 06:47:18, block 12,003,421, slot 11,445,836, IDs `98fe23ced589` `01ad4089dd58` | 06:49:03, block 12,003,429, slot 11,445,845, IDs `9e5001921a1c` `81fa106e99e1` |
| `down` | containers left: 0 | containers left: 0 |
| After `up -d` | 06:47:44, block 12,003,421, slot 11,445,836, IDs `9e5001921a1c` `81fa106e99e1` | 06:49:23, block 12,003,429, slot 11,445,845, IDs `9a4330ea2d45` `7d18497150dc` |
| Synced again | 06:48 (1 block behind the reference) | 06:55 (0 blocks behind) |

After the second restart the node needed a few minutes longer to catch up (7 blocks behind after one minute, with only 6 EL peers), see snapshot `3-after-restart-2`. Six minutes after the restart it was back at the head with 29 EL and 77 CL peers.

### No critical errors in logs

The log levels of the 24 hours before the restart test (from `1-before-restart`):

```
$ docker logs --since 24h geth | count by level
  14333 INFO
     17 WARN

$ docker logs --since 24h lighthouse | count by level
      1 CRIT
      9 ERROR
  29292 INFO
     54 WARN
```

Every WARN/ERROR/CRIT line is in [`logs-warn-error.txt`](evidence/1-before-restart/logs-warn-error.txt). Classification:

| Lines | Client | Message | Assessment |
|---|---|---|---|
| 1 CRIT, 1 ERROR, 53 WARN | Lighthouse | `Failed to update execution head`, `Error during execution engine upcheck`, `Execution engine call failed` … `http://geth:8551/ … operation timed out`, `State advance routine overloaded` | **One incident on 2026-10-26 from 15:12 to 15:18 UTC.** geth answered the Engine API too slowly for six minutes, and Lighthouse reported that the system might be overloaded. geth received some blocks up to 55 s late in that window (17× `Ignoring already known beacon payload`, all between 15:12 and 15:18). Afterwards everything ran normally without intervention, and no similar line appeared again. **The cause is not known** (see the note below). A short I/O or CPU peak, for example on the network-attached volume, would explain it, but it is not proven. |
| 8 ERROR | Lighthouse | `Error fetching payload envelope for peer … PayloadBodyMissingBlockAccessList` | Spread over the day. Another peer requested data for a block that our node could not serve. This affects only what we serve to others, not our own sync. **The exact cause was not investigated.** It is possibly related to the new block format of the Amsterdam fork. |
| 1 WARN | Lighthouse | `Banning builder that failed to reveal its payload` | Lighthouse ignores a block builder that misbehaved. Normal network behaviour. |
| 17 WARN | geth | `Ignoring already known beacon payload` | Part of the incident above. |

**Verdict:** no persistent critical error. One six-minute Engine API timeout with one CRIT line, which recovered on its own.

**Limitation:** `docker compose down` in the restart test also deletes the container logs. Before that, all WARN/ERROR/CRIT lines and the counts per level were saved, but not the INFO lines. That is why there is no log context for the incident, and why the time at which the first sync finished (about 2026-10-25 20:33 UTC, ~9.5 h after the start, seen in a live check) is not backed by a saved log file. A next run should copy the full logs before the restart test.

## Networking

### NAT/firewall situation

**No NAT by the provider.** The public IPv4 and IPv6 addresses sit directly on the server's interface, and the address seen from the Internet is the same:

```
$ ip -br addr
eth0             UP             138.201.155.69/32 metric 100 2a01:4f8:c17:4c0c::1/64 fe80::9000:aff:fe45:acf1/64

$ public IPv4 as seen from the Internet
138.201.155.69
```

There are three layers between the Internet and the clients:

```
Internet ──► Hetzner Cloud Firewall ──► eth0 138.201.155.69 ──► Docker port publishing (DNAT) ──► container
             stateful, inbound           no host firewall          P2P on all interfaces,
             allow-list                  (ufw inactive)            RPC on 127.0.0.1 only
```

1. **Hetzner Cloud Firewall** (in front of the server, outside the VM). It is stateful: answers to connections the node opens itself are allowed automatically. Inbound only the listed ports are allowed, everything else is dropped. There are no outbound rules, so outbound traffic is allowed, which the clients need to dial peers ([06](evidence/4-final/06-external-check.txt)):

   ```
   in tcp 22     from <admin IPv4>/32       SSH, only from the administrator's address
   in tcp 30303  from 0.0.0.0/0, ::/0       geth
   in udp 30303  from 0.0.0.0/0, ::/0       geth
   in tcp 9000   from 0.0.0.0/0, ::/0       Lighthouse
   in udp 9000   from 0.0.0.0/0, ::/0       Lighthouse
   in udp 9001   from 0.0.0.0/0, ::/0       Lighthouse
   ```

2. **Docker port publishing.** This is the only NAT in the setup: Docker forwards the published ports from the host to the container IPs on the internal network (`iptables -t nat` DNAT rules, [05](evidence/4-final/05-networking.txt)). The P2P ports are published on all interfaces, the RPC ports only on `127.0.0.1`. The Engine API (8551) is not published at all. Lighthouse reaches it over the internal Docker network. Inside the container the clients only see their internal IP (`172.18.0.x`), so both are told the public IP explicitly (`--nat=extip:` for geth, `--enr-address` for Lighthouse). Otherwise they would advertise an address that nobody can reach.

3. **Egress filter** (`scripts/egress-filter.sh`). P2P clients sometimes try to dial private addresses (10/8, 172.16/12, 192.168/16, 100.64/10) that they learned from other peers. On a hosting network that looks like a network scan and can lead to abuse reports, so these ranges are dropped on `eth0` for the host and for the containers.

   Known flaw of the version that ran: Hetzner's default gateway `172.31.1.1` is itself in 172.16/12, so packets addressed *to* the gateway (not routed through it), e.g. DHCP renewals, were also dropped. Normal traffic was not affected, and no problem was observed in 44 h. The script has since been fixed to allow the gateway.

**External test** from a host outside Hetzner ([06](evidence/4-final/06-external-check.txt)):

```
30303/tcp open    expected open    OK
9000/tcp  open    expected open    OK
8545/tcp  closed  expected closed  OK
8551/tcp  closed  expected closed  OK
5052/tcp  closed  expected closed  OK
```

UDP cannot be tested with a simple connect. The inbound peers on both layers (EL 27, CL 56, mostly over UDP/QUIC) show that the UDP ports are reachable as well.

### Required P2P ports

| Port | Protocol | Client | Purpose | Open inbound |
|---|---|---|---|---|
| 30303 | TCP | geth | devp2p / RLPx: block and transaction exchange with other execution clients | yes |
| 30303 | UDP | geth | discovery (discv4/discv5): finding other execution nodes | yes |
| 9000 | TCP | Lighthouse | libp2p: gossip and requests between consensus clients | yes |
| 9000 | UDP | Lighthouse | discv5: finding other consensus nodes | yes |
| 9001 | UDP | Lighthouse | libp2p over QUIC (most inbound CL peers use it) | yes |
| 8545 | TCP | geth | JSON-RPC (user API) | **no**, 127.0.0.1 only |
| 8551 | TCP | geth | Engine API (EL ↔ CL), JWT-authenticated | **no**, Docker network only |
| 5052 | TCP | Lighthouse | Beacon API | **no**, 127.0.0.1 only |

Without inbound reachability the node still works: it opens connections to other peers itself (outbound). But it never receives connections, so it has fewer and less diverse peers, and it does not help other nodes join the network.

### Why RPC ports must not simply be exposed to the Internet

The P2P ports speak protocols that are designed for untrusted peers: every message is validated, peers are scored, and misbehaving ones are disconnected. The RPC ports are different. They are interfaces for the **operator**, without any authentication (8545, 5052) or with a single shared secret (8551).

1. **No authentication, no rate limiting.** Anyone who finds the port can use the node. Bots scan the whole IPv4 space for open 8545 ports within hours.
2. **Denial of service.** Calls like `eth_call`, `eth_estimateGas`, `eth_getLogs` over large ranges, or `debug_trace*` cost a lot of CPU, memory and disk I/O. A few parallel requests can slow the node down until it falls behind the chain. The incident above shows how quickly a slow Engine API puts the consensus layer under pressure.
3. **Dangerous namespaces.** If `admin`, `debug`, `personal`, `miner` or `txpool` are enabled, an attacker can add or remove peers (eclipse attack), read internal data, or stop parts of the node. On nodes with unlocked accounts, attackers have stolen funds this way (the "Ethereum black valentine" attacks on open 8545 ports).
4. **The Engine API controls the execution layer.** Whoever can talk to 8551 decides which chain geth follows (`engine_forkchoiceUpdated`, `engine_newPayload`). It is protected only by the JWT secret, and it was never meant to be reachable from outside the machine.
5. **Information leaks.** The Beacon and JSON-RPC APIs reveal the client version, peers, sync state and, with validators, validator identities. This helps targeted attacks and deanonymisation.

In this setup the RPC ports are protected three times: they are published only on `127.0.0.1` (or not at all), the cloud firewall has no rule for them, and the external test confirms they are closed. The evidence scripts use them locally on the server, and peer details come from IPC, not from an `admin` API over HTTP.

Better options when remote access is needed:

- keep the ports on localhost and use an **SSH tunnel** or a **VPN** (WireGuard, Tailscale)
- or put a **reverse proxy** in front with authentication, TLS, rate limiting and an allowlist of read-only methods
- never expose `admin`/`debug`/`engine` methods

## Resource usage

| | |
|---|---|
| Disk | 421 GB on the volume (geth 405 GB, Lighthouse 17 GB) after 44 h |
| RAM | geth 8.0 GB, Lighthouse 1.4 GB |
| CPU | ~20 % each when synced (of 8 vCPU) |
| Traffic in 44 h | geth 291 GB in / 71 GB out, Lighthouse 96 GB in / 61 GB out |
| Sync time | geth snap sync ~9.5 h (live check, see the limitation above); Lighthouse followed the head within minutes |
| Cost | cpx42 €0.134/h + volume 1500 GB €0.141/h (Hetzner prices incl. 20 % VAT) ≈ €0.275/h, about €12 for 44 h |

The 1.5 TB volume was generous: with `--history.chain=postosaka` the node needed only 421 GB. A 1 TB volume would have been enough and slightly cheaper.

## Lessons learned

- **`eth_syncing = false` does not mean synced.** geth reports it before the sync starts. Check the block number against a reference and the CL's `is_optimistic` flag.
- **`docker compose down` deletes container logs.** Copy the logs before a restart test that recreates the containers.
- **Private address ranges can include your own gateway.** An egress filter needs an exception for it.
- **Inbound peers come quickly with a public IP.** Within four minutes of the first start both layers already had inbound peers. Most consensus peers use QUIC.
- **Pinned versions and history pruning pay off.** Pinned images make the setup reproducible, and the smallest history mode kept the disk usage at about 420 GB.
- **Short-lived infrastructure must be deleted.** The cloud server and volume are billed per hour as long as they exist, whether the node runs or not.
