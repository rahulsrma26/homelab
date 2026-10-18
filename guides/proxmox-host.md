# Setting up a Proxmox host

The steps every Proxmox host in this lab gets, in order. Steps marked **(situational)** are only for the case described. Host names are the roles from [architecture/hosts.md](../architecture/hosts.md): primary, secondary, backup.

---

## Step 0 — Installer

| Setting | Value |
|---|---|
| Filesystem | ZFS (RAID1 on two boot disks) |
| Advanced: `ashift` | 12 |
| Advanced: compression / checksum / copies | on / on / 1 |
| Advanced: **ARC max** | set here (e.g. 4096 MiB on a 48 GB host); later via `/etc/modprobe.d/zfs.conf` (`options zfs zfs_arc_max=<bytes>`) |
| Network | **pin interface names** (`nic0`, `nic1`), so they survive kernel and hardware changes |
| Hostname | the machine name |

---

## Bootloader Detection

Run this first — it determines which commands to use for kernel config changes throughout the guide:

```bash
bootctl status 2>/dev/null | grep -i "product" || echo "GRUB"
```

| Result | Bootloader | Kernel config file | Apply changes with |
|---|---|---|---|
| Shows `systemd-boot` | systemd-boot | `/etc/kernel/cmdline` | `proxmox-boot-tool refresh` |
| Shows `GRUB`, root on **ZFS** (ESPs managed by `proxmox-boot-tool`) | GRUB | `/etc/default/grub` | `proxmox-boot-tool refresh` (`update-grub` alone doesn't reach the ESPs) |
| Shows nothing / GRUB, root on **LVM** | GRUB | `/etc/default/grub` | `update-grub` |

| Host | Bootloader | Root FS |
|---|---|---|
| backup | systemd-boot | ZFS |
| secondary | GRUB | LVM |
| primary | GRUB (switched from systemd-boot) | ZFS |

### Switch systemd-boot → GRUB (situational)

**Only if** a ZFS install hangs at boot with `random-seed.c: Failed to flush random seed file: Time out`. This happens with some firmware NVMe drivers, e.g. the ODROID-H4 with PM983 drives.
- **Fix:** run [scripts/proxmox-grub-boot](../scripts/proxmox-grub-boot/README.md), which switches to GRUB and installs the update hook.
- **Background, rules and tests:** the script's README.

---

## Step 1 — Community Post-Install Script

Handles repos, subscription nag, HA services, and system update interactively:

```bash
DIAGNOSTICS=no bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
```

> `DIAGNOSTICS=no` disables telemetry (hardware specs + usage stats sent to community-scripts project).

Say **yes** to: fix sources, disable enterprise repo, enable no-subscription repo, fix the Ceph repo (disables Ceph enterprise; avoids apt errors), disable subscription nag, disable HA and Corosync (single node), update.
Say **no** to: pvetest repo.

---

## Step 2 — CPU Microcode

Updates CPU microcode — patches CPU-level security vulnerabilities and bugs:

```bash
DIAGNOSTICS=no bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/microcode.sh)"
```

Pick the **newest** `intel-microcode` package for the running Debian. Not a `deb12` build on Proxmox 9 / trixie; a newer build from unstable is fine. Reboot when prompted, then check it was applied:

```bash
journalctl -k -b | grep microcode    # "Updated early from: 0x…" = loaded; no line = the BIOS already had the same or newer
```

---

## Step 3 — Common Packages

```bash
apt install -y sudo htop iotop smartmontools lm-sensors nvme-cli
sensors-detect --auto
```

---

## Step 3b — Time Zone: UTC

```bash
timedatectl set-timezone Etc/UTC
timedatectl | grep 'Time zone'      # Etc/UTC (UTC, +0000)
```

- **Why:** one clock for every host, guest and log (labber gives the LXCs `Etc/UTC` too), sanoid's snapshot names are UTC, and no daylight-saving jumps (an hour repeated or skipped twice a year).
- **Schedules are UTC then:** backup jobs (`/etc/pve/jobs.cfg`), cron entries and alert times are read in UTC, which differs from the wall clock by your offset (and by an extra hour in summer where daylight saving applies). Set them with that in mind.
- No reboot needed; the actual time doesn't change, only how it's shown.

---

## Step 4 — Admin User

```bash
useradd -m -s /bin/bash <username>
passwd <username>
usermod -aG sudo <username>
```

Add to Proxmox datacenter (or via web UI: Datacenter → Permissions → Users → Add, then Permissions → ACL → Add):

```bash
pveum user add <username>@pam
pveum acl modify / -user <username>@pam -role Administrator
```

### SSH Key Setup (from your laptop)

Check for an existing key first — generate only if missing:

```bash
ls ~/.ssh/id_ed25519.pub
# if missing:
ssh-keygen -t ed25519 -C "<your laptop name>"
```

Copy to the host (enter password once, then passwordless from here on):

```bash
ssh-copy-id <username>@<ip>
```

Repeat `ssh-copy-id` for each Proxmox host — reuse the same key.

### Disable root SSH

**Open a second terminal and confirm the new user can SSH in before running this:**

```bash
ssh <username>@<ip>
```

Then disable root SSH:

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
```

> Proxmox web UI is unaffected — it uses root internally regardless of SSH config.

### Key-only SSH

Once every login has a key (e.g. in Termix):

```bash
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
sshd -T | grep -E 'permitrootlogin|passwordauthentication'    # both "no"
```

Passwords remain only for the console and the web UI.

---

## Step 4b — fail2ban

The web UI is the remaining password login, so protect it too ([Proxmox wiki: Fail2ban](https://pve.proxmox.com/wiki/Fail2ban)).

```bash
apt install -y fail2ban
```

`/etc/fail2ban/jail.local`:

```ini
[proxmox]
enabled  = true
port     = https,http,8006
filter   = proxmox
backend  = systemd
maxretry = 3
findtime = 2d
bantime  = 1h
```

`/etc/fail2ban/filter.d/proxmox.conf`:

```ini
[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
```

```bash
systemctl restart fail2ban
# one wrong web UI login, then:
fail2ban-client status proxmox                                   # "Currently failed: 1"
fail2ban-client status sshd | grep -E "Journal matches|File list" # Debian's default sshd jail must read the journal
```

- **Journal backend required:** there is no `/var/log/auth.log` or `daemon.log` on Proxmox 9 (no rsyslog), so jails must use `backend = systemd`. Debian's sshd jail already does.
- **Bans are per IP:** keep the web UI direct (`ip:8006`), never behind NPM. Otherwise one ban blocks the proxy, and everything behind it.
- **Tools get their own users:** give each tool its own user and API token (e.g. `monitoring@pve`). A tool with stale credentials then bans only its own IP. To unban: `fail2ban-client set proxmox unbanip <ip>`.

---

## Step 5 — ZFS rpool Tuning

**Skip on an LVM boot disk** (secondary: no ZFS rpool).

```bash
zfs set atime=off rpool          # the installer leaves atime=on
zfs get compression rpool        # the installer sets "on" (= lz4): nothing to do
```

- **Trim:** no `autotrim` needed on an NVMe-only rpool. Debian's `/etc/cron.d/zfsutils-linux` trims NVMe-only pools on the first Sunday of each month. A SATA pool needs `autotrim=on`, or `org.debian:periodic-trim=enable` for the monthly run.
- **recordsize:** leave the default (128K). VM disks are zvols and use `volblocksize` (Proxmox default 16K), so `recordsize` on `rpool/data` has no effect on them. LXC disks inherit 128K, which is fine. Set `1M` only on datasets for big media files.

### Import an existing data pool (situational)

**Only when reinstalling** a host whose data disks keep their pool (e.g. primary's `spool`):
- Import by disk ID, without mounting: `zpool import -d /dev/disk/by-id -f -N <pool>`.
- Inspect its datasets before mounting anything.
- Drop the reservation on dead zvols.
- Defer `zpool upgrade`.

**New disks:** check them before trusting them: SMART, a short self-test, link speed, CRC counts, and a load and temperature test (in the closed case, with the fans as they'll run).

---

## Step 6 — SMART Monitoring

```bash
systemctl is-enabled smartmontools; systemctl is-active smartmontools   # Debian enables it on install
```

> The unit is `smartmontools.service`. `smartd.service` is only an alias, so `systemctl enable smartd` fails with "Refusing to operate on linked unit file".

Configure `/etc/smartd.conf`. Comment out the stock `DEVICESCAN` line. smartd uses the **first** line that matches a device, so put the NVMe lines first:

```
/dev/nvme0 -a -W 4,70,80 -m root
/dev/nvme1 -a -W 4,70,80 -m root
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,45,55 -m root
```

- **NVMe limits:** they run hotter. The PM983s reach ~58 °C under load against an 86 °C warning limit, so the SATA limits (45/55) would alert all the time.
- **NVMe options:** NVMe drives don't support `-o`, `-S` or `-s` in smartd, so their lines leave them out.

```bash
systemctl restart smartmontools
journalctl -u smartmontools -b --no-pager | grep -iE "monitored|opened|error"
```

Test the alert path once: temporarily add `-M test` to `DEVICESCAN`, restart, and you should get one Telegram message per disk. Then remove it and restart again.

`-m root` sends mail to root. Proxmox passes root's mail into its notification system (`proxmox-mail-forward`), so SMART alerts reach Telegram through the matcher below.

---

## Step 6b — Notifications (Telegram)

Proxmox VE 8+ and PBS send their notifications (backup results, ZFS/ZED events, package updates, forwarded root mail) to **targets**, chosen by **matchers**. These steps are the same on PVE (Datacenter → Notifications) and on PBS (Configuration → Notifications).

### Webhook target

Notifications → Notification Targets → Add → **Webhook**:

| Field | Value |
|---|---|
| Name | `Telegram` |
| Method | `POST` |
| URL | `https://api.telegram.org/bot{{ secrets.token }}/sendMessage` |
| Header | `Content-Type` = `application/json` |
| Body | see below |
| Secrets | `token` = `<telegram-bot-token>`, `chat_id` = `<telegram-chat-id>` |

Body:

```json
{"chat_id": "{{ secrets.chat_id }}", "text": "host: ```{{ escape message }}```"}
```

- `{{ escape message }}` escapes the text for JSON. Without it, quotes or newlines in a message break the request.
- The token and chat ID go in **Secrets**, not in the URL or body. Proxmox stores secrets separately (in `/etc/pve/priv/`) and doesn't show them again in the UI.
- Click **Test**; a message must arrive in Telegram.
- Telegram rejects messages over 4096 characters, so a very long one (e.g. a full backup log) may not arrive. Add `{{ title }}` to the text if the message alone isn't clear.

### Matcher

Notifications → Notification Matchers → edit `default-matcher` → **Targets to notify**: tick `Telegram`, untick `mail-to-root`.

---

## Step 7 — CPU Governor (Optional)

Skip if the host will run compute-heavy workloads where latency matters. Recommended for 24/7 servers where power draw at idle is a priority.

```bash
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

Persistent via `/etc/tmpfiles.d/cpu-governor.conf`:

```
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave
```

---

## Step 8 — Network Interfaces

Both NICs in an **active-backup bond**, under one **VLAN-aware bridge**; the host's own address only on the management VLAN ([architecture/network.md](../architecture/network.md#hosts-one-bond-one-vlan-aware-bridge)). NIC names from `ip -br link` (`nic0` / `nic1` with pinned names), VLAN IDs from your switch.

```bash
# /etc/network/interfaces
auto lo
iface lo inet loopback

auto nic0
iface nic0 inet manual
auto nic1
iface nic1 inet manual

auto bond0
iface bond0 inet manual
    bond-slaves nic0 nic1
    bond-mode active-backup
    bond-primary nic0
    bond-miimon 100

auto vmbr0
iface vmbr0 inet manual
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids <mgmt-vid> <server-vid> <dmz-vid>     # only the VLANs this host's guests use

auto vmbr0.<mgmt-vid>
iface vmbr0.<mgmt-vid> inet static
    address 192.168.management.<host>/24
    gateway 192.168.management.1

source /etc/network/interfaces.d/*
```

Guests then use `bridge=vmbr0,tag=<vid>`. The switch ports become trunks with the same VLANs tagged and **native VLAN none** (a port profile for host ports, used for both NICs of every host).

**On a new install** with a console at hand, write the file and `ifreload -a`. **On a running host (one NIC per VLAN today), change it in an order that never cuts the host off:**

1. **Stop the guests** (planned downtime of a few minutes). Their old bridge goes away in step 3.
2. **The old guest NIC's switch port → the final host-port profile** (native VLAN none, all VLANs tagged). The host stays reachable on the old management NIC, which is untouched.
3. **Apply the new config with that NIC as the active link** (`bond-primary nic1`, if `nic1` was the guest NIC), and an automatic rollback: the old config comes back after 2 minutes unless you confirm from a new connection:
   ```bash
   cp /etc/network/interfaces /root/interfaces.before
   # write the new config (bond-primary = the old guest NIC) to /etc/network/interfaces.new, then:
   nohup sh -c 'cp /etc/network/interfaces.new /etc/network/interfaces && ifreload -a; sleep 120;
     [ -f /root/net-ok ] || { cp /root/interfaces.before /etc/network/interfaces && ifreload -a; echo rolled back; }' \
     > /root/net-apply.log 2>&1 &
   ```
   Reconnect to the host's address (unchanged), check `ip -br a` and `cat /proc/net/bonding/bond0` ("Currently Active Slave"), then `touch /root/net-ok` within the 2 minutes.
4. **The other NIC's port → the host-port profile too.** It's only the backup link now, so nothing drops.
5. **Move the guests** to the bridge with their tag (below) and start them.
6. **Test failover:** pull one cable, then the other. The active link switches and the host stays reachable. (`bond-primary` can stay as it is; it only decides which link is preferred when both are up.)

**Moving guests** (stopped first) from the old per-VLAN bridges to tags, in their config files. Management guests first, so the two replacements don't overlap:

```bash
cd /etc/pve
sed -i 's/bridge=vmbr0,/bridge=vmbr0,tag=<mgmt-vid>,/'   lxc/*.conf qemu-server/*.conf    # old management bridge
sed -i 's/bridge=vmbr1,/bridge=vmbr0,tag=<server-vid>,/' lxc/*.conf qemu-server/*.conf    # old guest bridge
grep -h '^net' lxc/*.conf qemu-server/*.conf                                               # every NIC: bridge=vmbr0,tag=…
```

Addresses don't change, so routes, firewall rules and DNS records stay valid. `systemctl restart networking` drops everything at once: use `ifreload -a`.

---

## Step 9 — Kernel Command Line

### A host with a GPU for passthrough, systemd-boot (backup)

Edit `/etc/kernel/cmdline`:

```
root=ZFS=rpool/ROOT/pve-1 boot=zfs quiet intel_iommu=on iommu=pt video=efifb:off
```

> `nofb nomodeset video=vesafb:off` — add only if the host kernel claims the dGPU (check `lspci -nnk` after reboot; if dGPU shows driver other than vfio-pci, add these). Not needed when iGPU handles host display.

```bash
proxmox-boot-tool refresh
```

### A host with a GPU for passthrough, GRUB on LVM (secondary)

Edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt video=efifb:off"
```

> Same note as above: add `nofb nomodeset video=vesafb:off` only if host driver claims the GPU.

```bash
update-grub
```

### A host without passthrough (primary)

No GPU passthrough — minimal cmdline. Edit `/etc/default/grub` (or `/etc/kernel/cmdline` if systemd-boot):

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

```bash
proxmox-boot-tool refresh   # ZFS root (GRUB or systemd-boot) — writes every ESP
update-grub                 # only on an LVM root without proxmox-boot-tool
```

---

## Step 10 — VFIO / GPU Passthrough

**Hosts with a discrete GPU for a VM only** (backup, secondary). Skip on primary.

### `/etc/modules`

Required — vfio modules must load early enough to claim devices before other drivers (e.g. `snd_hda_intel`) do:

```
vfio
vfio_iommu_type1
vfio_pci
```

### `/etc/modprobe.d/blacklist.conf`

```
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
```

### `/etc/modprobe.d/vfio.conf`

Get GPU IDs first:

```bash
lspci -nn | grep NVIDIA
```

```
options vfio-pci ids=10de:XXXX,10de:YYYY
```

**If the GPU disappears between VM starts** (seen with an RTX 5060 Ti): add `disable_idle_d3=1`, which keeps it out of D3cold:

```
options vfio-pci ids=10de:XXXX,10de:YYYY disable_idle_d3=1
```

### `/etc/modprobe.d/kvm.conf`

```
options kvm ignore_msrs=1 report_ignored_msrs=0
```

### Apply

```bash
update-initramfs -u -k all
proxmox-boot-tool refresh   # ZFS root (systemd-boot or GRUB)
update-grub                 # LVM root (GRUB)
reboot
```

### Verify after reboot

Run these in order. If each check passes, nothing else is needed — stop when everything looks good.

**1. IOMMU enabled**
```bash
dmesg | grep -e DMAR -e IOMMU
```
Expected: line containing `IOMMU enabled` or `DMAR: IOMMU enabled`. No output = IOMMU not active, check BIOS VT-d setting and kernel cmdline.

**2. Interrupt remapping**
```bash
dmesg | grep 'remapping'
```
Expected: `DMAR-IR: Enabled IRQ remapping in x2apic mode`. If missing, passthrough will fail (some boards need `allow_unsafe_interrupts`; prefer fixing it in the BIOS).

**3. VFIO modules loaded**
```bash
lsmod | grep vfio
```
Expected: vfio, vfio_iommu_type1, vfio_pci all present. If missing, add them to `/etc/modules` and rerun `update-initramfs -u -k all`.

**4. IOMMU groups — GPU must be in its own group**
```bash
pvesh get /nodes/$(hostname)/hardware/pci --pci-class-blacklist ""
```
Check that the GPU and its audio function share a group with no other devices. If grouped with unrelated devices, try a different PCIe slot or add `pcie_acs_override=downstream` to kernel cmdline.

**5. GPU bound to vfio-pci**
```bash
lspci -nnk | grep -A3 NVIDIA
```
Expected: `Kernel driver in use: vfio-pci`. If it shows `nouveau` or `nvidia`, blacklisting hasn't taken effect — recheck `/etc/modprobe.d/blacklist.conf` and rerun `update-initramfs -u -k all`.

---

## Step 11 — Reboot and Verify

```bash
reboot
```

After reboot:

```bash
# Confirm kernel cmdline applied
cat /proc/cmdline

# Confirm IOMMU (GPU hosts)
dmesg | grep -e DMAR -e IOMMU

# Confirm CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

---

## Step 12 — Follow-Up

| Host | Follow-up |
|---|---|
| all | **UPS:** NUT server or client per [power.md](../architecture/power.md), with [`scripts/nut`](../scripts/nut/) |
| hosts with ECC / in-band ECC | check that the kernel reports it (EDAC: `ls /sys/devices/system/edac/mc/`), so memory errors raise the monitoring alerts |
| all | **Disk encryption:** ZFS native + Tang, per [encryption.md](../architecture/encryption.md). Storages `enc-nvme` / `enc-sata` |
| all | **Tailscale LXC** on unencrypted storage (`local-zfs`), see below |
| all | **PBS:** storage + a nightly backup job (selection mode **All**, so new guests are included) + one restore test |
| hosts with data datasets | **sanoid** snapshots + TrueNAS pulling them (replication user, Proxmox host-firewall rule for TrueNAS): [backups.md](../architecture/backups.md) |
| all | **Monitoring:** [`services/monitoring/utils/install-exporters.sh`](../services/monitoring/utils/install-exporters.sh) (Alloy pushing metrics and the journal, smartctl exporter), a `monitoring@pve` user (PVEAuditor) for pve-exporter, and the host in Prometheus' pve-exporter targets |

### Tailscale LXC

Put it on **unencrypted** storage (`local-zfs`). It must start even when the encrypted datasets fail to unlock, because it's the remote path for the emergency unlock. On encrypted hosts, keep `local-zfs` for this LXC only, and have `zfs-unlock.service` use `WantedBy=pve-guests.service` rather than `RequiredBy`, or no guest starts at all when unlocking fails.
