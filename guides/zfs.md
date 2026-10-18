# ZFS: pools, datasets, tuning

The ZFS choices used on the Proxmox hosts and TrueNAS here, with the reasons and the mistakes worth avoiding. Encryption is its own guide: [zfs-encryption.md](zfs-encryption.md).

## Pools

```bash
ls -l /dev/disk/by-id/          # always build pools from these, never /dev/sdX (names change)
zpool create -o ashift=12 <pool> mirror /dev/disk/by-id/<disk-a> /dev/disk/by-id/<disk-b>
zpool create -o ashift=12 <pool> raidz1 /dev/disk/by-id/<a> /dev/disk/by-id/<b> /dev/disk/by-id/<c> /dev/disk/by-id/<d>
```

- **`ashift=12`** (4K sectors) even on drives that report 512 B. A too-small ashift means permanent write amplification and can't be changed later. Never mix ashift values in a vdev.
- **Which layout:** a mirror for boot and guest disks (fast, simple to replace); raidz1 for data on 4 SSDs or large HDDs, when another machine holds a second copy.
- **Enterprise SSDs with power-loss protection** for anything that holds data: consumer drives without PLP can lose acknowledged writes on a power cut, and must never be a separate log (SLOG) device.
- **Importing an existing pool** (after a reinstall): `zpool import -d /dev/disk/by-id -f -N <pool>` (by ID, without mounting), inspect its datasets before mounting anything, drop reservations on dead zvols (`refreservation=none`), and defer `zpool upgrade` until you're sure you won't need the old system.
- **New disks:** check them before trusting them: SMART, a short self-test, link speed and CRC counts, and a load and temperature test in the closed case.

## Datasets

```bash
zfs set compression=lz4 <pool>     # the Proxmox installer already sets "on" (= lz4)
zfs set atime=off <pool>           # the installer leaves atime on
```

- **recordsize:** the default 128K suits most data. `1M` for big files (photos, music, video, backups); `16K` for a database's own dataset. VM disks are zvols and use `volblocksize` (Proxmox default 16K), so `recordsize` doesn't affect them; LXC disks inherit 128K, which is fine.
- **One dataset per policy, not per app:** snapshots, replication and cloud sync attach to datasets ([architecture/storage.md](../architecture/storage.md)).
- **No deduplication:** it needs ~5 GB of RAM per TB and is rarely worth it.
- **Names aren't encrypted** even on encrypted datasets: keep them non-descriptive if that matters.

## Special vdev (metadata on SSD)

A mirrored pair of NVMe drives as a **special vdev** holds a pool's metadata and, optionally, its small blocks, which speeds up an HDD pool a lot.

- `special_small_blocks` works on **block size, not file size**: every block at or below the threshold goes to the special vdev. A file bigger than `recordsize` is stored in `recordsize` blocks, so with `special_small_blocks` at or above a dataset's `recordsize`, **all** of that dataset's data lands on the NVMe and fills it. Keep it well below `recordsize`, e.g.:
  ```bash
  zfs set special_small_blocks=64K <pool>     # with recordsize 128K–1M
  ```
- Changing it affects only new writes; existing blocks stay where they are until rewritten.
- **Losing the special vdev loses the pool.** Mirror it, and treat a failing special-vdev drive as urgently as a failing data drive.

## ARC (RAM cache)

ZFS uses up to half the RAM for its cache by default. On a hypervisor, cap it to leave room for guests: e.g. 4 GiB on a 48 GB host. Set it in the Proxmox installer (Advanced), or later:

```bash
echo "options zfs zfs_arc_max=$((4*1024*1024*1024))" > /etc/modprobe.d/zfs.conf
update-initramfs -u -k all        # takes effect at the next boot
arc_summary | head -30            # or: grep -E '^(size|c_max)' /proc/spl/kstat/zfs/arcstats
```

## Trim and scrub

- **Trim:** Debian's `/etc/cron.d/zfsutils-linux` trims NVMe-only pools on the first Sunday of each month, so they need no `autotrim`. A SATA SSD pool needs `autotrim=on`, or `org.debian:periodic-trim=enable` for the monthly run.
- **Scrub:** the same cron file scrubs every pool monthly. `zpool status` shows the last result.

## Watching

```bash
zpool status -x          # "all pools are healthy", or what isn't
zpool list               # capacity, fragmentation
zfs list -o name,used,avail,refer,compressratio
```

ZFS events (a faulted disk, a failed scrub) reach Proxmox's notification system through ZED; the monitoring stack also alerts on a pool that isn't ONLINE (`ZfsPoolNotOnline`).

## Drive timeouts and errors

If SATA drives drop out or time out under ZFS: in the BIOS, **Aggressive LPM Support = Disabled** and **VMD = Disabled**, then check `smartctl -a` for CRC errors (a cable).
