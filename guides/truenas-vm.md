# TrueNAS in a VM

TrueNAS Scale as a VM on a Proxmox host, with its disks on a passed-through HBA and a mirrored NVMe special vdev. It holds the bulk storage, the pulled replicas of other machines' data, and the off-site sync ([architecture/backups.md](../architecture/backups.md)). ZFS background: [zfs.md](zfs.md).

## VM

| Setting | Value | Notes |
|---|---|---|
| Machine / BIOS | q35 / OVMF (UEFI) | PCIe passthrough; EFI disk on encrypted storage, **pre-enrolled keys off** |
| CPU | host, 4 cores | |
| RAM | 24 GB | ZFS uses the headroom for its cache |
| SCSI controller | VirtIO SCSI single | |
| Display | **VirtIO-GPU** | the TrueNAS Scale installer doesn't work with Default or Standard VGA |
| OS disk | VirtIO block on the host's encrypted storage | |

## Passthrough

- **HBA:** an LSI 9211-8i (SAS2008) flashed to **IT mode**, passed through as a whole PCIe device (PCI-Express on). IT mode is essential: IR (RAID) firmware hides the individual disks from ZFS. Check its firmware is P20 (`cat /sys/class/scsi_host/host*/version_fw` → `20.00.07.00`).
- **A second HBA**, if disks for other VMs (PBS's datastore, a GPU VM's pool) hang off it, stays with the host: pass those disks through individually by ID, never that HBA.
- **NVMe drives** for the special vdev: as PCI devices (PCI-Express on; All Functions and ROM-Bar at defaults). Check each sits alone in its IOMMU group.
- **Slot widths:** a ×8 HBA in a slot that's electrically ×4 links at `5 GT/s x4`: ~2 GB/s, plenty for a few HDDs (`lspci -vv -s <id> | grep LnkSta`).

## Pool

- **Data:** raidz1 of large CMR HDDs (enterprise, e.g. 22 TB helium drives); room in the HBA's other bays to add a second vdev later.
- **Special vdev:** a **mirror** of two enterprise NVMe (power-loss protection): metadata and small blocks on flash. Losing it loses the pool: treat a failing special-vdev drive as urgently as a failing HDD.
- **`special_small_blocks` below every dataset's `recordsize`**, e.g. `64K` on the pool with `recordsize=1M` on media. It works on block size: with the threshold at or above `recordsize`, every block goes to the NVMe. A wrong value once put a whole media library (2.6 TB) on the special vdev while the HDDs held 23 GB.

**Moving a dataset's data off the special vdev** (the settings only affect new writes, so the data has to be rewritten): send it into a new dataset, then swap names. An encrypted dataset can't be sent with its properties unless raw, so send without `-R`/`-p` and set the properties again on the receive side:

```bash
zfs set special_small_blocks=64K tank
zfs snapshot tank/media@m1
zfs send -v tank/media@m1 | zfs recv -u -o recordsize=1M -o atime=off <other properties…> tank/media_new
# stop everything using it (shares, apps, NFS clients), then catch up and swap
zfs snapshot tank/media@m2
zfs send -v -I @m1 tank/media@m2 | zfs recv -u tank/media_new
zfs rename tank/media tank/media_old && zfs rename tank/media_new tank/media && zfs mount tank/media
# compare file counts and ownership, then: zfs destroy -rv tank/media_old
```

An NFS client mounted on the old dataset sees a stale handle afterwards: `umount -l <mount> && mount -a`.

## Datasets

The same tiers as the other machines ([architecture/storage.md](../architecture/storage.md)): `tank/vault`, `tank/common`, `tank/media`, `tank/extra` (scratch, never backed up), and `tank/replicas/<host>/<dataset>` for pulled replicas, receive-only. Replication settings and their traps: [architecture/backups.md](../architecture/backups.md#second-copy-truenas-pulls).

## Maintenance schedule

Spread so no two jobs hit the same disks at once:

| When | Job | Where |
|---|---|---|
| Sunday 00:00 (if the last scrub is 35+ days old) | scrub the pool | Data Protection → Scrub Tasks |
| Tuesday 02:00 | SMART short test, HDDs | System → Advanced → Cron Jobs |
| first Wednesday of the month, 01:00 | SMART long test, HDDs (~2 days on 22 TB) | Cron Jobs |
| Saturday 03:00 | TRIM (SSDs only; auto-TRIM off) | Cron Jobs |
| daily / weekly / monthly | periodic snapshots of TrueNAS's own datasets | Data Protection → Periodic Snapshot Tasks |

**Cron jobs** run as root, with *Hide Standard Output* on and *Hide Standard Error* off, so a failure raises an alert:

```bash
# SMART short, 0 2 * * 2
for d in /dev/sd[a-d]; do /usr/sbin/smartctl -t short $d; done
# SMART long, 0 1 1-7 * *  (days 1–7; exits unless it's Wednesday)
[ "$(LC_ALL=C date | cut -c1-3)" = Wed ] || exit 0; for d in /dev/sd[a-d]; do /usr/sbin/smartctl -t long $d; done
# TRIM, 0 3 * * 6  (skipped while a scrub or resilver runs)
/usr/sbin/zpool status tank | grep -q -E 'scrub in progress|resilver in progress' || /usr/sbin/zpool trim tank
```

- **Full paths:** cron's PATH may lack `/usr/sbin`, and "Run Now" in the UI doesn't prove the cron environment works.
- **No `%`** in cron commands (cron turns it into a newline), hence `date | cut` instead of `date +%u`.
- **"First Wednesday":** with both day-of-month and day-of-week set, cron ORs them, so the schedule covers days 1–7 and the command checks the weekday itself.
- **Widen `/dev/sd[a-d]`** when drives are added. Results: `smartctl -l selftest /dev/sdX | head -8`. NVMe drives may not support self-tests at all.

**Periodic snapshot tasks:** each needs its **own naming schema** (TrueNAS expires snapshots by matching the schema, so two tasks sharing one delete each other's), and "Allow taking empty snapshots" off. Recursive on the pool covers new datasets from day one; exclude only churning, recreatable data, and never the replica datasets (they get their snapshots from the source).

**Restoring a file:** `/mnt/tank/<dataset>/.zfs/snapshot/<name>/` (read-only), or SMB Shadow Copies for Windows "Previous Versions".

## Alerts

System → Alert Settings: send to Telegram. A failed replication or cloud sync then raises an alert, and its success clears it, both as messages.
