# Architecture

How this homelab is designed and why: the machines and their roles, the network, where data lives and how it is protected. The rest of the repo is the implementation ([`labber/`](../labber/), [`services/`](../services/), [`scripts/`](../scripts/)); these documents are the context it is built for. Step-by-step how-tos are in [`guides/`](../guides/).

Real addresses, names and credentials are not here. Addresses use the repo's placeholder format, e.g. `192.168.server.immich`.

## At a glance

```
                               internet
                                  │
                              ┌───┴────┐
                              │ router │   VLANs: management · server · dmz ·
                              └───┬────┘          home · iot · camera · guest
          ┌───────────────────────┼───────────────────────┐
  ┌───────┴────────┐     ┌────────┴────────┐     ┌────────┴────────┐
  │    primary     │     │    secondary    │     │     backup      │
  │ daily services │     │ GPU · cameras   │     │ TrueNAS · PBS   │
  │ important data │     │ public VM (dmz) │     │ GPU VM · Kuma   │
  │ ECC · ZFS      │     │ no important    │     │ ECC · ZFS · HDD │
  └───────┬────────┘     │ data            │     └────────┬────────┘
          │              └────────┬────────┘              │
          │                       ▲                       ├──► cloud (encrypted)
          │          Cloudflare Tunnel (public services)  │
          │                                               │
          ├── sanoid snapshots ──► pulled by TrueNAS ─────┤
          └── guest disks ───────► PBS ───────────────────┘

  tang-a, tang-b (small boards): the keys that unlock the encrypted disks at boot
```

| Host | Role | Runs |
|---|---|---|
| **primary** | everyday services that hold important data | Immich, Paperless, Joplin, Home Assistant, Vaultwarden, monitoring, Traefik, files (Samba + Filebrowser), apps |
| **secondary** | services without important data, the experimental, and the public entry | Frigate (camera events), a GPU VM for local LLMs, voice and chat, the public VM |
| **backup** | storage, backups, heavy GPU | TrueNAS (bulk storage + replicas of primary's data), PBS, a GPU VM, Uptime Kuma |

Details: [hosts.md](hosts.md).

## Documents

| Document | What it covers |
|---|---|
| [principles.md](principles.md) | goals, and the rules that decide where things run |
| [hosts.md](hosts.md) | each machine: hardware class, role, what runs on it, failover |
| [network.md](network.md) | VLANs, NICs and bridges, address scheme, firewall policy, DNS, names, remote and public access |
| [services.md](services.md) | the guests on each host and how services are grouped into them |
| [storage.md](storage.md) | datasets by importance, mounts, ownership, read-only rules |
| [backups.md](backups.md) | snapshots, replication, PBS, off-site, restores |
| [encryption.md](encryption.md) | ZFS encryption unlocked by Tang at boot, threat model, emergency unlock |
| [power.md](power.md) | UPSes, shutdown order, coming back after an outage |
| [monitoring.md](monitoring.md) | metrics and logs, alert rules and how alerts are delivered |
| [security.md](security.md) | access, hardening, exposure, secrets |

## Names used here

| Name | Meaning |
|---|---|
| primary, secondary, backup | the three Proxmox hosts |
| tang-a, tang-b | two single-board computers running Tang (disk-unlock keys) |
| guest | a VM or LXC on a Proxmox host |
| `vault`, `common`, `media` | the three data tiers (datasets) on primary, mirrored on TrueNAS |
| labber | this repo's tool that sets up guests and deploys services into them |
