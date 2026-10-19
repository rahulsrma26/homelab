# Principles

## Goals

- **Low maintenance.** The lab is for using, not for weekend repairs. Prefer the simplest setup that works; automate updates where it is safe; make failures loud.
- **Important data is safe.** Photos and documents survive a dead disk, a dead host, a bad upgrade, ransomware inside a guest, and the house burning down.
- **Low power.** Everything always-on draws about 200 W. Heavy machines are on only when needed or shut down early on battery.
- **Recovers by itself.** After a power cut, every machine comes back, unlocks its disks and starts its services without anyone at the keyboard.
- **Reproducible.** A host or guest can be rebuilt from this repo plus its backups.



## Where things run

1. **Important data only on machines with ECC memory and redundant ZFS.** That is primary and backup. A machine without them (secondary) runs services whose data can be lost or rebuilt. "Non-essential" there means *no important data*, not *not always on*.
2. **Proxmox on every server; every workload is a guest.** No bare-metal services on the hypervisors.
3. **LXC first.** A VM only where it's required: a full OS of its own (Home Assistant OS), a discrete GPU passed through, disks passed through (TrueNAS, PBS), or privileged CI workloads needing their own kernel boundary (Forgejo runner).
4. **iGPUs are shared into LXCs** (`/dev/dri`), never passed through, so several guests can use one.
5. **Own guest** when other services depend on it, it holds secrets, it needs particular hardware or placement, or its updates and crashes must not affect others: Vaultwarden, the reverse proxy, DNS, Tailscale, Authelia, monitoring, Immich.
6. **Grouped** when apps share a lifecycle and hold the same kind of data: the document apps together (Paperless, Joplin, Trilium), the light apps together (music, start page, browser tools).
7. **No orchestration.** No Kubernetes, no cluster: Docker Compose inside LXCs, deployed with labber. A cluster would need more always-on machines and more maintenance than it saves.
8. **Movable guests.** Guests that could run on another host during maintenance or a failure keep their address wherever they run (see [network.md](network.md)).



## How things are built

- **Configuration lives in this repo**; a guest is set up with `labber setup` and services are deployed with `labber <service> install`. Secrets are filled in at install time from templates and never committed.
- `main` **is what machines install from.** Changes go to `dev`; CI promotes `dev` to `main` only when every test passes.
- **Datasets by importance, not by app.** Snapshot and backup policies attach to datasets, so data with the same importance shares one dataset (see [storage.md](storage.md)).
- **UTC everywhere** on servers and guests: one clock for logs, schedules and snapshot names, and no daylight-saving jumps.

