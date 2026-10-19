# Services and guests

Each service is a folder in [`services/`](../services/) (a `docker-compose.yml`, an `.env.example` with templates, a README), deployed into an LXC or VM with labber. This page is where they run and why they're grouped that way.

## primary


| Guest              | Type                     | Services                                                                     | Data                                   | Why its own guest / why grouped                           |
| ------------------ | ------------------------ | ---------------------------------------------------------------------------- | -------------------------------------- | --------------------------------------------------------- |
| **immich**         | LXC, iGPU                | Immich (server, Postgres, Valkey, local ML on the iGPU)                      | `vault/photos`                         | the most important app; frequent upgrades; needs the iGPU |
| **docs**           | LXC                      | Paperless-ngx, Joplin Server, Trilium                                        | `vault/docs`, `common/inbox`           | document apps: same kind of data, same lifecycle          |
| **apps**           | LXC                      | Navidrome, Homepage, base-utils (IT-Tools, omni-tools, BentoPDF, LibreSpeed) | `media`, `common/apps`                 | light apps with nothing irreplaceable                     |
| **files**          | LXC                      | Filebrowser, Samba ([`scripts/smbmgr`](../scripts/smbmgr/))                  | the datasets (`vault` read-only, `extra/share`) | serves primary's own disks, so tied to primary            |
| **traefik**        | LXC                      | Traefik (`lan` mode)                                                         | —                                      | everything depends on it                                  |
| **monitoring**     | LXC, NIC in both VLANs   | Prometheus, Loki, Grafana, Alertmanager, InfluxDB, pve-exporter              | own volumes                            | must run longest in an outage, so on the low-power host   |
| **n8n**            | LXC, server              | n8n: alert event collection and daily summaries                            | workflows, credentials, alert history   | its own lifecycle; holds automation credentials           |
| **forgejo**        | LXC, server              | Forgejo: local Git, private repositories, Actions and GitHub publishing | `vault/git` (repositories, SQLite, keys, Actions logs) | important data; CI runs elsewhere, so no workflow can reach it ([guide](../guides/forgejo-setup.md)) |
| **garage**         | LXC, server              | Garage: S3 object storage for Forgejo's Actions artifacts and packages      | `extra/garage`                         | rebuildable data, never backed up; on primary because Forgejo won't start without its storage |
| **tailscale**      | LXC, unencrypted storage | Tailscale                                                                    | —                                      | remote path for an emergency unlock                       |
| **vaultwarden**    | LXC                      | Vaultwarden                                                                  | own volume                             | holds every password: nothing else in its guest           |
| **home-assistant** | VM (Home Assistant OS)   | Home Assistant                                                               | inside the VM; its backups to TrueNAS  | needs its own OS; wakes secondary after power cuts        |
| **dns**            | LXC, management          | Technitium (main)                                                            | —                                      | everything depends on names                               |
| **sso**            | LXC, management          | Authelia + LLDAP                                                             | own volumes                            | the login in front of other services                      |




## secondary


| Guest         | Type                 | Services                                                                    |
| ------------- | -------------------- | --------------------------------------------------------------------------- |
| **frigate**   | LXC, iGPU (OpenVINO) | Frigate: object detection on the camera streams                             |
| **gpu-vm**    | VM, workstation GPU  | local LLMs (llama.cpp), voice assistant agent, chat UIs                     |
| **public VM** | VM, `dmz` VLAN       | Traefik (`cf` mode) behind a Cloudflare Tunnel; the public share-link proxy |
| **ci**        | VM, server           | the Forgejo runner: labber's privileged Docker tests, disposable checkouts and caches. Its Docker access controls only this VM, which holds nothing irreplaceable |




## backup


| Guest           | Type                   | Services                                                     |
| --------------- | ---------------------- | ------------------------------------------------------------ |
| **truenas**     | VM, HBA passed through | TrueNAS: bulk storage, replicas, off-site sync, backups of the Linux and macOS computers (e.g. Time Machine) |
| **pbs**         | VM                     | Proxmox Backup Server                                        |
| **gpu-vm**      | VM, RTX GPU            | large models; a backup Immich ML worker for big re-indexing  |
| **uptime-kuma** | LXC, management        | Uptime Kuma                                                  |
| **jellyfin**    | LXC, iGPU              | Jellyfin                                                     |




## Conventions

- **One compose project per service folder**; several projects can share an LXC.
- **Ports:** host ports are set in each service's `.env` (templated defaults). Light tools use the 7000s (`base-utils`), so they don't collide with other services' defaults.
- **Optional parts** are compose profiles chosen at install (e.g. Immich's local machine learning): `COMPOSE_PROFILES` in `.env`.
- **Data on bind mounts**, not Docker volumes, wherever the data matters, so it lands in the right dataset and its snapshots.
- **Updates:** `labber check-updates` runs daily and reports per service; `labber <svc> update` pulls the new images (and repo files), waits for the containers to come up healthy and offers a rollback if they don't. Upgrades that migrate data (Immich) are done one release at a time, after a snapshot.

