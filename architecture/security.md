# Security

The lab is private by default: nothing on the LAN is reachable from the internet, and the few public services are isolated on their own VM.

## Exposure

- **No inbound ports.** Remote access is Tailscale ([network.md](network.md#remote-access)); public services go through a Cloudflare Tunnel to the public VM only, in its own VLAN on the host without important data ([network.md](network.md#public-access)).
- **VLANs split by trust:** the server VLAN can't reach management (hosts, Tang); home devices reach only service ports; IoT and cameras are isolated; guests get internet only.
- **Every published port is a decision.** Services listen only where something needs them: a port that only containers in the same project use isn't published to the host. In the monitoring stack, only what other machines push to (Prometheus, Loki) and Grafana are published; exporters and Alertmanager stay on the stack's own network.

## Access

- **SSH:** key-only everywhere; no root login on hosts (key-only root on LXCs, set by `labber setup`); `fail2ban` on SSH and on the Proxmox web UI (journal backend: Proxmox 9 has no auth log files).
- **Machine accounts are restricted:** e.g. the replication user may only `zfs send`, with a key that works only from TrueNAS and only to run commands.
- **Tools get their own Proxmox users and API tokens** (monitoring, Home Assistant read-only), so a tool with stale credentials bans only its own address.
- **The Proxmox web UI is reached directly**, never through the reverse proxy: fail2ban bans per address, and a ban on the proxy's address would block everything behind it.
- **Out-of-band console** on the management VLAN, internet blocked.

## Data

- **Encrypted at rest** (ZFS native, Tang at boot: [encryption.md](encryption.md)).
- **Off-site copies are encrypted before they leave** (rclone crypt). PBS backups stay on PBS's encrypted disk (theft-safe), without client-side encryption.
- **Snapshots on the host** can't be seen or deleted from inside a guest, so ransomware in a guest can't take them out.

## Secrets

- **Never in the repo.** Services get theirs at install time: `.env.example` holds templates (`{{ name | generate(hex64) }}`, …), and labber fills them in or asks ([CLAUDE.md](../CLAUDE.md)).
- **Lint on every push** (`make test-lint`, also a pre-push hook): templates, private addresses, keys, `.env` files, e-mail addresses, Tailscale names, time zones naming a place, and a local denylist of personal words. It checks the working tree and the commits being pushed.
- **The password manager** holds what must survive the lab: the ZFS raw keys and emergency passphrases, Tang keys, the cloud copy's encryption password and salt, TrueNAS's pool key.

## Updates

- `unattended-upgrades` on every guest (set by `labber setup`), with a check for stuck security updates.
- Service images: `labber check-updates` daily; updates applied with a health check and rollback.
- Hosts: Proxmox updates by hand; big ones are tried on a spare machine or a test VM first.
