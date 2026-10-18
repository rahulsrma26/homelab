# Hosts

Three Proxmox hosts, plus a few small devices that support them.


|                     | primary                                             | secondary                                                          | backup                                                    |
| ------------------- | --------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------- |
| **Role**            | everyday services with important data               | services without important data; GPU experiments; the public entry | storage, backups, heavy GPU                               |
| **CPU**             | 8-core low-power (Intel N305, 15 W)                 | 14-core mobile (Intel i9-12900H)                                   | 20-core desktop (Intel i7-14700)                          |
| **Max Memory**      | 48 GB, in-band ECC                                  | 96 GB, no ECC                                                      | 96 GB, ECC                                                |
| **Boot + guests**   | ZFS mirror of 2 enterprise NVMe (`rpool`)           | single disk (LVM) + one large U.2 NVMe (ZFS, no redundancy)        | ZFS mirror (boot) + ZFS mirror (guests)                   |
| **Data**            | 4 enterprise SATA SSDs, raidz1 (`spool`), encrypted | —                                                                  | TrueNAS: 4 large HDDs raidz1 + NVMe special vdev (mirror) |
| **GPU**             | iGPU (shared into LXCs)                             | RTX 2000E Ada 16 GB GPU (VM) + iGPU                                 | RTX 5060 Ti 16 GB GPU (VM) + iGPU                          |
| **On battery**      | runs longest; shuts down at low battery             | shuts down after 2 min                                             | shuts down after 5 min, cutting its UPS                   |
| **Important data?** | yes                                                 | **no**                                                             | yes (replicas, backups)                                   |




## primary

The machine that matters day to day. Low power, so it runs longest on its UPS and records whole outages; ECC and a redundant ZFS pool, so it may hold important data.

- **Guests:** see [services.md](services.md). Everything that holds irreplaceable data (photos, documents, passwords) runs here, plus the infrastructure others depend on: reverse proxy, DNS, SSO, monitoring and Home Assistant.
- **Storage:** guests on `rpool` (encrypted), data on `spool/encrypted/{vault,common,media}` bind-mounted into the LXCs ([storage.md](storage.md)).
- **Encryption:** unlocked at boot by Tang ([encryption.md](encryption.md)). A Tailscale LXC on **unencrypted** storage starts even if the unlock fails, as the remote path for an emergency unlock.
- **Power:** the NUT server for its UPS, which also powers the camera recorder and the managed switches ([power.md](power.md)).



## secondary

Fast, lots of memory, a GPU, but no ECC and no redundant storage, so **nothing irreplaceable lives here**.

- **Frigate** (LXC, iGPU with OpenVINO): object detection on the camera streams. The cameras' own recorder does the recording, so losing Frigate loses detection, not footage.
- **GPU VM** (workstation GPU): local LLMs for the voice assistant and chat UIs, experiments.
- **Public VM:** the only thing reachable from the internet, through a Cloudflare Tunnel, with its own hardened Traefik, in its own DMZ VLAN ([network.md](network.md#public-access)). It lives here because a compromise that escaped the VM would find nothing irreplaceable: on backup it would sit next to every backup, on primary next to the originals. It is stateless, so the missing ECC and redundancy don't matter for it.
- Other VMs/LXCs for testing and experimentation.
- Shuts down 2 minutes into a power cut (heavy draw, nothing to save) and is woken by Home Assistant when power returns.



## backup

Big disks and the backup systems, so it holds the second copy of everything.

- **TrueNAS** (VM, HBA passed through): bulk storage, the pulled replicas of primary's data, and the off-site sync ([backups.md](backups.md)).
- **PBS** (VM): Proxmox Backup Server for every host's guests.
- **GPU VM** (RTX GPU): large models, gaming; also a backup machine-learning worker.
- **Uptime Kuma** (LXC): watches everything, including primary's monitoring stack, from a different machine.
- **Jellyfin** (LXC, iGPU).



## Support devices


| Device                 | What it does                                                                                                                                                                                                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **tang-a**, **tang-b** | two single-board computers, bare metal, on the management VLAN. Each runs Tang, which hands out the keys that unlock the hosts' encrypted disks at boot. Both are the secondary DNS servers. On ordinary power, away from the hosts and from each other; they boot in under a minute when power returns, before any host asks. |
| **Synology NAS**       | an older NAS: a local copy target for TrueNAS's own data                                                                                                                                                                                                                      |
| **KVM over IP**        | out-of-band console for backup; on the management VLAN with internet blocked                                                                                                                                                                                                  |




## Failover

There is no automatic failover. If primary is down for long:

1. Guests that are **movable** (their addresses are in the shared range, see [network.md](network.md)) are restored from PBS onto backup, keeping their addresses.
2. Their data isn't on backup's local disks: they mount the **TrueNAS replicas** of `vault`, `common` and `media`, promoted to read-write while primary is away.
3. When primary is back, the changes are replicated back before the guests move home.

This is a written, manual procedure, tested once a year.