# Storage

## Data tiers

Data is split by **how much it matters**, not by app: snapshot and backup policies attach to datasets, so each dataset holds data with one policy.

| Dataset (on primary) | Tier | Holds | recordsize | Copies |
|---|---|---|---|---|
| `spool/encrypted/vault` | irreplaceable | `photos/` (Immich's library, incl. its own database dumps), `docs/` (Paperless's whole data dir: database and files together), `git/` (Forgejo's repositories and database) | 1M | primary + TrueNAS + cloud (+ a yearly offline archive) |
| `spool/encrypted/common` | would hurt to lose | shares, general files, `inbox/` (scans for Paperless), `apps/` (per-app config, e.g. Homepage's YAML) | 128K | primary + TrueNAS |
| `spool/encrypted/media` | re-obtainable | `music/` (`library/`, `staging/`) | 1M | primary + TrueNAS |
| `spool/encrypted/extra` | scratch | `share/` (an SMB share), `garage/` (a child dataset: object storage for rebuildable data) | 1M (`garage`: 128K) | primary only: no snapshots, never backed up |
| LXC disks (`rpool`, encrypted) | app state | app configs, Postgres (Immich, Joplin), SQLite (Trilium) | — | PBS |

Secondary has no data tiers, only `npool/encrypted/extra`: scratch on its single U.2, shared over SMB, never backed up.

TrueNAS uses the same tiers for its own data (`tank/vault`, `tank/common`, `tank/media`), plus `tank/extra` (scratch, never backed up) and `tank/replicas/<host>/<dataset>` for what it pulls from other machines.

## Mounts

The data datasets live on the **host** and are bind-mounted into the LXCs. There is no NAS VM and no network share between a host's own guests.

| LXC | `vault/photos` | `vault/docs` | `media` | `common` |
|---|---|---|---|---|
| immich | rw | — | — | — |
| docs | — | rw | — | `inbox/` rw |
| apps | — | — | rw | `apps/` rw |
| files | **ro** | **ro** | rw | rw |

- **Read-only where an app owns the files.** Immich and Paperless track their files in a database, so changes behind their back break it. New files go in through the apps' own import paths (`common/inbox` → Paperless; Immich's upload).
- **Data mount points are excluded from PBS** (`backup=0`): PBS keeps the LXC disks, ZFS replication keeps the data.

## Ownership

Unprivileged LXCs map uid *n* to host uid 100000 + *n*. Check each app's runtime uid before `chown`:

- Paperless runs as uid 1000 (host 101000); Immich's server as root (host 100000).
- Samba writes everything as the file server's root (100000), via `force user` per share. Paperless can still delete imported scans because `common/inbox` itself belongs to 101000.

## Pools

- **primary:** `rpool` (ZFS mirror of two enterprise NVMe: Proxmox and guest disks) and `spool` (raidz1 of four enterprise SATA SSDs: the data). Both encrypted below an `encrypted` dataset ([encryption.md](encryption.md)).
- **backup:** a ZFS mirror for Proxmox, another for guests, and TrueNAS's `tank` on the passed-through HBA: raidz1 of four large HDDs with a mirrored NVMe **special vdev** for metadata and small blocks.
  - `special_small_blocks` works on **block** size, not file size: with it at or above a dataset's `recordsize`, *all* of that dataset's data goes to the NVMe. Keep it well below `recordsize` (e.g. 64K with 128K–1M records).
  - Losing the special vdev loses the pool, so a failing NVMe there is as urgent as a failing data disk.

## Names

`files` is a word apps use for their own routes (Filebrowser's URLs start with `/files/`, which broke editing below the first folder), so the shared dataset is called `common`.
