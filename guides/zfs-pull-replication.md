# ZFS snapshots and pull replication to TrueNAS

A Proxmox host's data datasets snapshotted by **sanoid**, and **pulled** by TrueNAS over SSH into its own encrypted pool. The host holds no credentials to TrueNAS, and TrueNAS can do nothing on the host but read snapshots. Design and policies: [architecture/backups.md](../architecture/backups.md); the dataset tiers: [architecture/storage.md](../architecture/storage.md).

```
host: sanoid snapshots ──(TrueNAS connects by SSH as a send-only user)──► tank/replicas/<host>/<dataset>
```

## 1. Snapshots: sanoid (on the host)

```bash
apt install -y sanoid
```

Debian's package brings a timer (every 15 minutes) but **no config**, so until `/etc/sanoid/sanoid.conf` exists it silently does nothing. **Set every value** in each template: anything left out takes sanoid's defaults (e.g. 48 hourly, 90 daily).

```ini
[<pool>/encrypted/vault]
	use_template = vault
[<pool>/encrypted/common]
	use_template = common
[<pool>/encrypted/media]
	use_template = media

# irreplaceable: an hour's undo
[template_vault]
	frequently = 0
	hourly = 24
	daily = 30
	weekly = 0
	monthly = 12
	yearly = 0
	autosnap = yes
	autoprune = yes

[template_common]
	frequently = 0
	hourly = 0
	daily = 14
	weekly = 0
	monthly = 3
	yearly = 0
	autosnap = yes
	autoprune = yes

# re-obtainable: a week, so re-encoding doesn't pile up in snapshots
[template_media]
	frequently = 0
	hourly = 0
	daily = 7
	weekly = 0
	monthly = 0
	yearly = 0
	autosnap = yes
	autoprune = yes
```

```bash
sanoid --cron --readonly --verbose      # dry run
sanoid --cron --verbose                 # the first real run
zfs list -t snapshot -o name,used -s creation | grep autosnap
systemctl list-timers 'sanoid*' --no-pager
```

- Names are `autosnap_<date>_<time>_<type>`, in **UTC** (the service runs with `TZ=UTC`). By hand, run `TZ=UTC sanoid --cron` so names stay consistent. Manual snapshots with other names are never touched.
- New snapshots show `0B`: a snapshot costs only what changes after it.
- Restore a file from `/<dataset>/.zfs/snapshot/<name>/` (read-only). Avoid `zfs rollback`: it deletes every newer snapshot.

## 2. A send-only user (on the host)

```bash
useradd -m -s /bin/sh zfsbackup && usermod -p '*' zfsbackup
for ds in vault common media; do zfs allow -u zfsbackup send spool/encrypted/$ds; done
zfs allow spool/encrypted/vault                                       # check
su -s /bin/sh zfsbackup -c 'zfs list -t snapshot -o name spool/encrypted/vault | tail -2'
```

- **No password** (`*`, not `passwd -l`: some SSH setups refuse key logins for a "locked" account). It only ever logs in with TrueNAS's key.
- **Only `send`:** it can list and send snapshots, nothing else. No sudo: sudo for `zfs` could destroy every dataset. (`hold,release` would let a source keep snapshots TrueNAS still needs, but TrueNAS's Pull tasks can't use holds.)
- **A shell is needed** (`/bin/sh`): TrueNAS runs its `zfs` commands through it.

## 3. TrueNAS's key

On TrueNAS: **Credentials → Backup Credentials → SSH Keypairs → Add → Generate Keypair**. Copy its **public** key into the user's `authorized_keys` on the host, limited to TrueNAS's address and to running commands:

```bash
install -d -m 700 -o zfsbackup -g zfsbackup /home/zfsbackup/.ssh
echo 'from="<truenas-ip>",restrict ssh-rsa AAAA… truenas-pull' > /home/zfsbackup/.ssh/authorized_keys
chown zfsbackup:zfsbackup /home/zfsbackup/.ssh/authorized_keys && chmod 600 /home/zfsbackup/.ssh/authorized_keys
```

`restrict` turns off the terminal, port, agent and X11 forwarding; commands still run. SSH ignores the file if its permissions are looser than this.

## 4. Firewall: two places

1. **The VLAN rule:** TrueNAS → the host's SSH, TCP 22 only. Ping fails by design (ICMP isn't allowed): test with `nc -zvw3 <host> 22` from TrueNAS.
2. **The Proxmox host firewall:** with the datacenter firewall on, a host accepts SSH and the web UI only from its management network. Node → Firewall → Add: `IN ACCEPT -source <truenas-ip> -p tcp -dport 22`.

Symptom of a missing second rule: on the host, `tcpdump -ni any host <truenas-ip> and tcp port 22` shows TrueNAS's SYNs arriving and no replies.

## 5. The SSH connection (TrueNAS)

**Credentials → Backup Credentials → SSH Connections → Add:** setup method **Manual**, the host's management address, port 22, user `zfsbackup`, the key pair from step 3, **Discover Remote Host Key**.

## 6. The target datasets (TrueNAS)

`tank/replicas` (encrypted with a **key**, not a passphrase, so it unlocks by itself after a reboot; or inherited from an encrypted pool root), and `tank/replicas/<host>` below it. **Export the key** (Datasets → Encryption → Export Key) into your password manager. Don't create the per-dataset targets: the first run does.

## 7. Replication tasks (TrueNAS)

Data Protection → Replication Tasks → Add → **Advanced Replication Creation**, **one task per dataset**:

| Setting | Value |
|---|---|
| Direction / Transport | PULL / SSH, the connection from step 5 |
| Use Sudo For ZFS Commands | **off** (the `zfs allow` user instead) |
| Stream Compression | Disabled (photos and music don't compress) |
| Allow Blocks Larger than 128KB | **on** (1M recordsize datasets) |
| Allow Compressed WRITE Records | on |
| Source | one dataset |
| Recursive / Include Dataset Properties / Full Filesystem Replication | **all off** |
| Snapshots to include | **Matching regular expression**: `autosnap_.*_(hourly\|daily\|monthly)` (vault), `autosnap_.*_(daily\|monthly)` (common); a dataset with a single type (media) can use the naming schema `autosnap_%Y-%m-%d_%H:%M:%S_daily` |
| Save Pending Snapshots | off |
| Destination | the **full** target: `tank/replicas/<host>/<dataset>` |
| Destination Dataset Read-only Policy | **SET** |
| Encryption | **on + Inherit Encryption**, key fields empty |
| Replication from scratch | off |
| Snapshot Retention Policy | **Same as Source** |
| Run Automatically + Schedule | **both on**: vault hourly at :15, the others daily after midnight UTC |
| Only Replicate Snapshots Matching Schedule | **off** |

Then **Run Now**, the smallest dataset first: it shows quickly whether everything works. The first run sends everything (e.g. ~150 GB in ~25 minutes over one SSH stream); later runs send only what changed.

### Why each setting (the traps)

| Trap | Result | Fix |
|---|---|---|
| Destination set to the parent (`tank/replicas/<host>`) | with a **single** source, the destination *is* the receiving dataset: it would be overwritten | the full path |
| A **naming schema** with several snapshot types | sanoid takes daily + hourly (and monthly on the 1st) in the **same second**; TrueNAS orders by the date in the name, can't order equal ones, and stops: "existing snapshot … is newer … but has an older date in the snapshot name" | a **regular expression**: TrueNAS then follows ZFS's creation order |
| Switching an existing task from schema to regex in the UI | "Naming regex can't be used with Naming schema": the old schema stays stored | recreate the task, or set it from the TrueNAS shell (below) |
| Include Dataset Properties on | an encrypted source may arrive **raw**, locked with the source's key: unreadable on TrueNAS (no cloud sync, no failover) | off |
| Encryption unchecked under an encrypted parent | "Refusing to transfer … without properties and without replication task encryption" | Encryption on + Inherit Encryption |
| Read-only policy REQUIRE | it only *checks*, and fails on a new dataset | SET |
| Retention None | every snapshot is kept forever; custom retention is a single age, not tiered | Same as Source |
| Save Pending Snapshots on | "Pull replication tasks can't hold pending snapshots" | off; the source's long retention keeps a common snapshot (monthlies) through weeks of outage |
| Schedule without Run Automatically | "You can't have schedule for replication that does not run automatically" | both on |
| Only Replicate Snapshots Matching Schedule | snapshots are on the hour, the task runs at :15: nothing matches | off |
| Sudo prompt for a non-root user | passwordless sudo would give the user full control | no; `zfs allow` |

Setting a task from the TrueNAS shell (ids: `sudo midclt call replication.query | jq '.[] | {id, name}'`):

```bash
sudo midclt call replication.update <id> '{"naming_schema": [], "also_include_naming_schema": [], "name_regex": "autosnap_.*_(hourly|daily|monthly)", "retention_policy": "SOURCE"}'
```

A task recreated in the UI with a regex may come out with retention None: check `retention_policy` in the query.

**First run with the clash already hit:** if a run failed after receiving one snapshot of a same-second pair, the other one (created just before it) can't be sent afterwards, and the task reports "no snapshots to send". That's harmless: later snapshots build on the one that arrived.

## 8. Check

```bash
# on TrueNAS
sudo zfs get -r -o name,property,value encryptionroot,readonly,used tank/replicas/<host>
sudo zfs list -t snapshot -o name,used -r tank/replicas/<host> | tail
ls /mnt/tank/replicas/<host>/vault/
```

| Check | Should be |
|---|---|
| `encryptionroot` | TrueNAS's own (`tank/replicas` or the pool root), nothing from the source |
| `readonly` | `on` for each replica |
| snapshots | the source's `autosnap_…` names |
| files | readable: real folders, not a locked dataset |

**Alerts:** System → Alert Settings → Telegram. A failed task raises an alert, and its next success clears it, as two messages.

**Common snapshot:** incremental pulls need one snapshot both sides still have. Datasets with monthlies resume after a long outage; a dataset with only 7 dailies needs a full resend after more than a week down (fine for re-obtainable data).
