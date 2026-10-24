# Handoff: run a Sepolia node (geth + Lighthouse) on the home server

You (Claude) are taking over this task in a new session on the user's **home server**. The previous session ran on the user's Windows laptop. It analysed the task and agreed the concept with the user, but nothing has been installed or started yet. This file has everything you need. Read all of it before doing anything.

## Working with the user

- Talk to the user in **German**. Code, comments, commit messages and file contents are in English.
- **You do the technical work.** The user does what needs their accounts or physical access: router settings and submitting the assignment. Tell them exactly what to click.
- Check facts on the server instead of assuming them (OS, disk, network, versions). Look up current client versions and flags in the official docs or release pages. Do not rely on memory, and do not use `latest` image tags.
- When you claim something works, back it up with command output.
- The work lives in the user's course repo **https://github.com/CloudusCodus/blockchain-dev** (branch `main`), in this folder `sepolia-node/`. Commit with clear messages. Ask before pushing if anything sensitive could be included.

## The assignment (verbatim)

> Operate a testnet node aka run the blockchain
>
> We go with a rather classical Ethereum Sepolia testnet setup with geth + Lighthouse.
>
> Make your node demonstrate that it is synchronized and well connected.
>
> You must provide evidence for:
>
> **Execution layer:** Geth running · Geth synchronized · current block number · execution peers · inbound/outbound connectivity
>
> **Consensus layer:** Lighthouse running · Lighthouse synchronized · consensus peers · inbound/outbound connectivity
>
> **Infrastructure:** Docker containers running · persistent blockchain data · no critical errors in logs
>
> **Networking:** explain your NAT/firewall situation · identify required P2P ports · explain why RPC ports should not simply be exposed to the Internet

## Goal in one sentence

Run geth (execution layer) and Lighthouse (consensus layer) as Docker containers on the home server, let them fully sync Sepolia, make the P2P ports reachable from the Internet, and produce a report with command output as evidence for every point above.

## What the previous session found out

- **Disk size is the main risk.** Measured in October 2026, a synced Sepolia geth + Lighthouse node needs about **570 GB with pruned history** and about **980 GB with full history** ([source](https://github.com/aws-samples/aws-blockchain-node-runners/issues/349)). It also keeps growing. geth stops when the disk is almost full during snap sync and cannot resume. The user wants the node **as small as possible**. You need an **SSD** (NVMe preferred); an HDD is too slow to sync.
- **Why not the laptop:** it is on the university network (eduroam). It sits behind the university's NAT with a shared public IPv4 and has no port forwarding, so inbound peers were impossible there. That is why the node moves to the home server, where the user controls the router.
- Whether the home connection has a real public IPv4 is **unknown**. It could be CGNAT or DS-Lite. You check that.

## Target architecture

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

- **Published to the Internet:** only the P2P ports. 30303 TCP+UDP for geth; 9000 TCP+UDP and 9001 UDP (QUIC) for Lighthouse. Verify these defaults against the docs of the versions you use.
- **Engine API 8551:** not published at all. geth and Lighthouse talk over the internal Docker network, authenticated with a shared JWT secret.
- **JSON-RPC 8545 and Beacon API 5052:** published on `127.0.0.1` only, for the evidence scripts. Do not enable `admin`/`debug` over HTTP. For geth peer details, use IPC inside the container (`docker exec geth geth attach --exec '…' /data/geth.ipc`). Check the IPC path for your datadir.
- **Keep it small:**
  - geth: snap sync, path-based state scheme (the default in current geth), and drop pre-merge history (`--history.chain postmerge` or whatever the current geth offers; check the docs).
  - Lighthouse: checkpoint sync (e.g. `https://checkpoint-sync.sepolia.ethpandaops.io`; check the current list of Sepolia checkpoint providers). Not a supernode. Keep the default blob pruning. No validator.
- **NAT:** tell both clients the public IP so they advertise it. For geth: `--nat extip:<public IPv4>`. For Lighthouse: `--enr-address <public IPv4>`, plus the matching ENR port flags if needed.
- `restart: unless-stopped` on both containers, and log rotation (`max-size`/`max-file`) so the logs do not fill the disk.

## Workflow

### Phase 0: inspect the server (report the results to the user first)

1. OS, kernel, CPU, RAM. Target: at least 16 GB RAM, 4+ cores.
2. Disks: free space, SSD or HDD (`lsblk -d -o NAME,ROTA,SIZE,MODEL`), filesystem. Put the data directory on the SSD with the most free space. **If less than about 650 GB is free, tell the user before going on.**
3. Docker and Docker Compose installed? If not, install them using the official method for that OS.
4. Network:
   - Local IP and gateway.
   - Public IPv4 as seen from outside (`curl -4 https://api.ipify.org`). Ask the user for the WAN IP their router shows. If the two differ, or the WAN IP is in `100.64.0.0/10` → CGNAT, and IPv4 port forwarding will not work.
   - IPv6: does the server have a global address? Is DS-Lite in use?
   - Is UPnP available? (It does not replace manual port forwarding; just note it.)
   - Is a host firewall active (ufw, firewalld, nftables)?
5. Write the findings to `evidence/00-environment.txt`.

If CGNAT or DS-Lite: explain the consequences to the user. Options are asking the ISP for a public IPv4, running P2P over IPv6 (both clients support it), or documenting outbound-only operation and explaining why. Let the user decide.

### Phase 1: set up in the repo (`sepolia-node/`)

```
sepolia-node/
├── HANDOFF.md              (this file)
├── README.md               report for the submission (Phase 5)
├── docker-compose.yml
├── .env.example            image versions, data path, public IP (no secrets)
├── scripts/
│   ├── gen-jwt.sh          openssl rand -hex 32 > jwt/jwt.hex
│   └── collect-evidence.sh writes all evidence to evidence/
├── evidence/               command output, committed
├── jwt/                    git-ignored
└── data/                   git-ignored (or outside the repo via .env)
```

- `.env` (real values), `jwt/` and `data/` must be in `.gitignore`. Never commit the JWT secret.
- Pin image versions (`ethereum/client-go:vX.Y.Z`, `sigp/lighthouse:vX.Y.Z`) to the current stable releases. Look them up on GitHub Releases. Sepolia must be supported by those releases, so check for recent hard forks.

### Phase 2: open the ports (user + Claude)

1. Set up the host firewall: allow 30303/tcp, 30303/udp, 9000/tcp, 9000/udp, 9001/udp. Do **not** open 8545, 8551 or 5052.
2. Router port forwarding to the server's LAN IP for the same ports. **The user does this.** Give them a precise list of the ports, protocols and target IP. The server needs a fixed LAN IP or a DHCP reservation.
3. Put the public IP into `.env`. If it is dynamic, write that down for the report.

### Phase 3: start and sync

1. Run `scripts/gen-jwt.sh`, then `docker compose up -d`.
2. Watch the logs:
   - Lighthouse should finish its checkpoint sync within minutes.
   - geth snap sync takes hours, up to about a day. Snap sync only starts once Lighthouse is providing the head.
3. Keep an eye on disk growth during the sync (`df -h`, `du -sh data/*`).
4. Report progress to the user regularly with block height and sync status.

### Phase 4: collect the evidence (`scripts/collect-evidence.sh`)

The script writes one timestamped file per area to `evidence/`. Run it only when both clients are synced, and include the output in the report.

| Requirement | How to prove it |
|---|---|
| Geth running | `docker ps` (status, uptime), `web3_clientVersion` |
| Geth synchronized | `eth_syncing` → `false` |
| Current block number | `eth_blockNumber` (decimal) compared with `https://sepolia.etherscan.io` at the same time (difference only a few blocks) |
| Execution peers | `net_peerCount`, plus via IPC `admin.peers.length` |
| EL inbound/outbound | via IPC: `admin.peers.filter(p => p.network.inbound).length` and `!p.network.inbound`, plus `admin.nodeInfo.enode` (shows the advertised public IP) |
| Lighthouse running | `docker ps`, `GET /eth/v1/node/version`, `GET /eth/v1/node/health` (200) |
| Lighthouse synchronized | `GET /eth/v1/node/syncing` → `is_syncing: false`, `is_optimistic: false`, `el_offline: false`; head slot compared with a public Sepolia beacon explorer |
| Consensus peers | `GET /eth/v1/node/peer_count` |
| CL inbound/outbound | `GET /eth/v1/node/peers?state=connected`, count by `direction` (`inbound`/`outbound`); `GET /eth/v1/node/identity` (ENR with public IP and ports) |
| Docker containers running | `docker compose ps`, `docker stats --no-stream` |
| Persistent data | `docker inspect` (mounts), `du -sh data/*`; then `docker compose restart`: the node continues from the same block instead of starting over (before and after values in the file) |
| No critical errors | `docker logs --since 24h <c> 2>&1 \| grep -Ei 'crit\|fatal\|error'` for both containers. Classify each hit; many WARN/ERROR lines about individual peers are normal. |
| Ports reachable from outside | Inbound peers > 0 on both layers. Optionally an external TCP port check of 30303/9000 (e.g. from a mobile hotspot with `nc -vz <public-ip> 30303`). |

### Phase 5: write the report (`sepolia-node/README.md`)

- Setup overview (diagram, versions, flags and why each one).
- One section per evidence area with the relevant command output excerpts, linked to the files in `evidence/`.
- **Networking:**
  - The actual NAT/firewall situation at home: router NAT, port forwarding, host firewall, Docker port publishing; CGNAT/DS-Lite if it applies.
  - A table of the P2P ports (port, protocol, client, purpose: devp2p/discv4/discv5/libp2p/QUIC).
  - Why RPC ports must not be exposed:
    - Anyone could call the API without authentication: read the node's state and call expensive methods (`eth_call`, `eth_getLogs`, `debug_*`), which is a DoS risk.
    - If `admin`/`personal` namespaces or unlocked accounts are enabled, funds can be stolen. Bots constantly scan the Internet for open 8545 ports.
    - The Engine API (8551) controls which chain the EL follows. Exposed, it is a critical attack surface, even with the JWT, because brute force and side channels remain.
    - The Beacon API leaks information and is also a DoS risk.
    - The right approach: localhost only; remote access via SSH tunnel or VPN; if needed, a reverse proxy with authentication, rate limiting and a method allowlist.
- Resource use (disk, RAM) and lessons learned.

## Definition of done

- [ ] Both containers running, both clients synced (evidence files written)
- [ ] Inbound **and** outbound peers on both layers, or a documented reason why inbound is not possible plus what was tried
- [ ] Restart test shows persistent data
- [ ] Logs checked, no critical errors (or explained)
- [ ] README report complete, networking questions answered
- [ ] Committed to `blockchain-dev` (no secrets, no chain data), pushed after the user agrees
- [ ] The user knows what to submit
