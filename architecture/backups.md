# Backups

## The rule: 3-2-1 for what matters

Three copies, on two different machines, one off-site: for `vault` (photos, documents, Git repositories). Less important tiers get fewer copies ([storage.md](storage.md)).

| What | Undo (on the same machine) | Second machine | Off-site |
|---|---|---|---|
| `vault` | sanoid snapshots: hourly ×24, daily ×30, monthly ×12 | TrueNAS pulls every hour | cloud storage, client-side encrypted (+ a yearly offline archive) |
| `common` | daily ×14, monthly ×3 | TrueNAS pulls daily | — |
| `media` | daily ×7 (short, so re-encoding the library doesn't pile up in snapshots) | TrueNAS pulls daily | — |
| `extra` | — | — | — (scratch, and object storage for rebuildable data: never backed up) |
| guest disks | — | PBS nightly, all guests | — |
| TrueNAS's own data | TrueNAS snapshots | the Synology NAS (pulls with rsync/Hyper Backup: it can't receive ZFS) | cloud for `tank/vault` |

Snapshots are the fast "undo": they protect against deleted files, a bad upgrade and ransomware *inside* a guest (guests can't see the host's snapshots). They don't protect against a dead pool, the host's root, or a fire: that's what the other copies are for.

## Snapshots: sanoid

[sanoid](https://github.com/jimsalter/sanoid) on each host with data datasets: a systemd timer every 15 minutes takes and prunes snapshots per dataset, with the policies in the table above. Names are `autosnap_<date>_<time>_<type>`, in UTC. Manual snapshots (other names) are never touched.

## Second copy: TrueNAS pulls

TrueNAS **pulls** over SSH, so the source holds no credentials to TrueNAS:

- **A send-only user on the source:** `zfs allow … send` on the data datasets, no sudo, no password, its key accepted only from TrueNAS's address and only to run commands.
- **Two firewalls let it through:** the VLAN rule and the source's Proxmox host firewall, each for TrueNAS → SSH only.
- **Not raw:** replicas are received into TrueNAS's own encryption, so TrueNAS can read them for the off-site sync and a failover.
- **One task per dataset**, retention **Same as Source** (TrueNAS keeps what sanoid keeps), into `tank/replicas/<host>/<dataset>`, read-only.
- **Snapshots matched by regular expression**, because sanoid takes snapshots of different types in the same second, which a date-based naming schema can't order.

Step by step, with every setting and the pitfalls: [guides/zfs-pull-replication.md](../guides/zfs-pull-replication.md).

## Guest disks: PBS

A nightly backup job on every host to PBS on backup, snapshot mode, **selection "All"** so new guests are included without editing the job. Data mount points are excluded (`backup=0`). No client-side encryption: PBS's own disk is encrypted at rest, which covers a stolen disk, not someone inside the running PBS.

## Off-site: cloud

A TrueNAS Cloud Sync task pushes `replicas/<host>/vault` (and TrueNAS's own `vault`) to a cloud storage provider, with **Remote Encryption** (rclone crypt), so the provider sees only scrambled names and contents.

- Excluded: what an app can regenerate (Immich's `thumbs/` and `encoded-video/`).
- SYNC mode (a mirror); history comes from TrueNAS's monthly snapshots and the provider's own file history.
- The password and salt are kept outside the lab; without them the copy can't be read.
- **No "take snapshot"** on a replica: an extra snapshot there breaks the next replication.
- **Test a restore early**: pulling rclone-encrypted files back has had reported problems.

## Restoring

- **Immich is restored as a matched pair:** its database (LXC disk, PBS) and its library (`vault/photos`) are backed up at different times. Restore the library from a snapshot **plus the database dump inside that same snapshot**, not a PBS database from another time; otherwise photos go missing or orphaned.
- **Paperless** has no such gap: its database and files are in one dataset.
- **Test restores, yearly:** one file from a snapshot, one guest from PBS, one Immich pair, one folder from the cloud copy.
- **Alerts:** TrueNAS (failed replication or sync), PBS and Proxmox send to Telegram; a failure *and* its recovery both arrive.
