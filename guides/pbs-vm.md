# Proxmox Backup Server in a VM

PBS as a VM on one host, with its datastore on a passed-through disk, backing up the guests of every host. Running it as a VM rather than on the hypervisor itself follows Proxmox's own recommendation, and lets the datastore move to a new PBS install with the disk.

Design and policy: [architecture/backups.md](../architecture/backups.md#guest-disks-pbs).

## VM

| Setting | Value | Notes |
|---|---|---|
| Machine / BIOS | i440fx / SeaBIOS | no PCIe passthrough needed |
| CPU / RAM | 2 cores / 4 GB | |
| SCSI controller | VirtIO SCSI single | |
| OS disk | 32 GB on the host's **encrypted** storage, VirtIO, IO thread on, no cache | the datastore key lives on it (below) |
| Backup of the OS disk | off | PBS doesn't back up itself into itself |
| Network | `vmbr0` with the management VLAN's tag, VirtIO, static address | the hosts reach it on the management VLAN |
| QEMU agent | on (install `qemu-guest-agent`) | |

**The datastore disk**, passed through by ID, attached **before** starting the installer:

```bash
lsblk -o NAME,SIZE,VENDOR,MODEL,SERIAL                 # on the host
qm set <VMID> --scsi1 /dev/disk/by-id/ata-<model>_<serial>
```

A spinning disk: no discard, no SSD emulation, no cache.

## Install

Boot the PBS ISO; target the VirtIO OS disk; a static address on the management VLAN. Then:

```bash
DIAGNOSTICS=no bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pbs-install.sh)"
apt install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent
```

Set up Telegram notifications the same way as on the hosts ([proxmox-host.md](proxmox-host.md), step 6b).

## An encrypted datastore

The datastore is a ZFS pool encrypted with a key file. The key file sits on the VM's OS disk, which is itself on the host's encrypted storage, so a stolen disk is unreadable and the VM still starts unattended.

```bash
dd if=/dev/urandom of=/root/zfs-backups.key bs=32 count=1 && chmod 600 /root/zfs-backups.key
zpool create -o ashift=12 \
  -O encryption=aes-256-gcm -O keyformat=raw -O keylocation=file:///root/zfs-backups.key \
  -O compression=lz4 -O atime=off \
  backups /dev/sdb
base64 /root/zfs-backups.key      # save this in your password manager now, then clear the scrollback
                                  # (not in a web terminal that records sessions)
```

**Load the key at boot.** ZFS imports the pool but leaves it locked:

```bash
cat > /etc/systemd/system/zfs-load-key-backups.service <<'EOF'
[Unit]
Description=Load ZFS encryption key for backups pool
DefaultDependencies=no
After=zfs-import-cache.service zfs-import-scan.service
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zfs load-key backups

[Install]
WantedBy=zfs-mount.service
EOF
systemctl daemon-reload && systemctl enable zfs-load-key-backups.service
```

Then in the web UI: **Datastore → Add**, path `/backups`. Set **pruning** (e.g. keep-daily 7, keep-weekly 4, keep-monthly 6) and a **verify** job.

This covers theft of the disk, not someone inside the running PBS; for that, enable client-side encryption on the hosts' PBS storage (`pvesm set <pbs-id> --encryption-key autogen`) and keep `/etc/pve/priv/storage/<id>.enc` safe. Do that at the latest before any copy of the datastore leaves the house.

## Users and the hosts

1. **Configuration → User Management → Add:** `backup@pbs`, a strong password.
2. **Datastore → backups → Permissions → Add → User Permission:** path `/datastore/backups`, user `backup@pbs`, role **DatastoreBackup** (back up and restore its own backups); DatastoreAdmin only if the hosts should prune and verify too. Propagate on.
3. On each Proxmox host: **Datacenter → Storage → Add → Proxmox Backup Server**: the PBS address, `backup@pbs`, its password, datastore `backups`; check and accept the fingerprint.
4. **Datacenter → Backup → Add:** storage = PBS, nightly, mode **snapshot**, selection **All** (exclude what shouldn't be backed up), so new guests are included without editing the job. Data mount points are left out with `backup=0` on each mount.

**A guest that rarely changes** (e.g. the Tailscale LXC): one backup, marked **Protected** in the datastore's content view, so pruning never removes it.

## Recovering after losing the PBS VM

Reinstall PBS, attach the same datastore disk, then:

```bash
umask 077; read -rsp 'base64 key: ' k; echo; printf '%s' "$k" | base64 -d > /root/zfs-backups.key; unset k
# (read -s: the key never appears on screen or in the shell history)
zpool import backups
zfs load-key backups && zfs mount backups
```

Re-create the key-loading service (above), add the datastore again at `/backups` (**Datastore → Add**, existing path): every backup is still there.
