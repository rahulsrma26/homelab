# Guides

Step-by-step how-tos for building the pieces of this lab. The design they serve, and why, is in [`architecture/`](../architecture/).

| Guide | What it covers |
|---|---|
| [proxmox-host.md](proxmox-host.md) | a new Proxmox host: installer, repos, admin user and SSH, fail2ban, UTC, ZFS, SMART, notifications, network, kernel cmdline, follow-up |
| [zfs.md](zfs.md) | pools, datasets, recordsize, the special vdev pitfall, ARC, trim and scrub |
| [zfs-encryption.md](zfs-encryption.md) | ZFS native encryption unlocked at boot by two Tang servers, emergency unlock, tests, re-binding |
| [tang-server.md](tang-server.md) | a bare-metal Tang server on an Orange Pi Zero 3: OS, SSH, fewer SD writes, keys, updates |
| [ecc.md](ecc.md) | hardware ECC and in-band ECC: enable, verify, alert |
| [gpu-passthrough.md](gpu-passthrough.md) | a discrete NVIDIA GPU to a VM: BIOS, host, VM settings, per-generation notes, troubleshooting |
| [new-guest.md](new-guest.md) | a new LXC or VM: conventions, creation, `labber setup` |
| [tailscale-lxc.md](tailscale-lxc.md) | the Tailscale LXC for remote access: TUN device, subnet routes, key expiry, split DNS |
| [zfs-pull-replication.md](zfs-pull-replication.md) | sanoid snapshots and TrueNAS pulling them: the send-only user, both firewalls, every task setting and its trap, checks |
| [public-tunnel-vm.md](public-tunnel-vm.md) | the public VM behind a Cloudflare Tunnel: three firewall switches, the tunnel (CLI, not the dashboard), Traefik `cf` mode, SSH, Cloudflare settings, rebuilding it |
| [disk-check.md](disk-check.md) | checking a disk before trusting it: link, SMART counters, self-tests, a load and temperature test in the closed case, a baseline |
| [pbs-vm.md](pbs-vm.md) | Proxmox Backup Server as a VM: passed-through disk, encrypted datastore, users, jobs, recovering it |
| [truenas-vm.md](truenas-vm.md) | TrueNAS as a VM: HBA and NVMe passthrough, special vdev (and fixing a wrong `special_small_blocks`), maintenance schedule and cron pitfalls |
| [igpu-lxc.md](igpu-lxc.md) | sharing the Intel iGPU into unprivileged LXCs: BIOS, device mapping, checks; Jellyfin, Frigate, Immich settings |
| [monitoring-setup.md](monitoring-setup.md) | deploying the monitoring stack: the Proxmox user, the LXC, hosts, guests, Home Assistant, checks, a test alert |
| [asus-pro-ws-w680-ace.md](asus-pro-ws-w680-ace.md) | the ASUS Pro WS W680-ACE board: PCIe layout, BIOS settings and why, checks, host notes |
| [odroid-h4-ultra/](odroid-h4-ultra/) | the ODROID-H4 Ultra board: hardware limits, which BIOS image, updating and recovering the BIOS, settings |
| [odroid-h4-ultra/bios-options.md](odroid-h4-ultra/bios-options.md) | every BIOS 1.12 menu and option as shown on screen, with help text |

Related, next to the code: [`scripts/nut`](../scripts/nut/) (UPS shutdown), [`scripts/proxmox-grub-boot`](../scripts/proxmox-grub-boot/) (systemd-boot → GRUB), [`scripts/smbmgr`](../scripts/smbmgr/) (Samba shares), [`labber`](../labber/) (guest setup and services).

## Quick fixes

| Symptom | Fix |
|---|---|
| a UPS's USB connection drops while the machine is off or in standby | BIOS: **ErP Ready = Disabled** (ErP cuts USB power in standby); then `lsusb` and `upsc <ups>@localhost` |
| SATA drives time out under ZFS | BIOS: Aggressive LPM Support and VMD **Disabled**; `smartctl -a` for CRC errors ([zfs.md](zfs.md)) |
| a passed-through GPU vanishes between VM starts | `disable_idle_d3=1` ([gpu-passthrough.md](gpu-passthrough.md)) |
| a Proxmox ZFS host hangs at boot with `random-seed … Time out` | boot with GRUB: [`scripts/proxmox-grub-boot`](../scripts/proxmox-grub-boot/) |
| a guest's Proxmox firewall rules don't apply | the guest's own firewall switch (`enable: 1`) and the datacenter firewall must be on, besides the NIC's `firewall=1` ([new-guest.md](new-guest.md)) |
