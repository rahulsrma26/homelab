# scripts

One-off host scripts, each meant to be run straight from GitHub with a single command.

**As root.** On a machine where you log in as a normal user with `sudo` (e.g. an Orange Pi), switch to root first with `sudo -i`. `sudo bash <(curl …)` fails with `/dev/fd/63: No such file or directory`, because sudo closes the descriptor the downloaded script is passed through. Don't use `curl … | sudo bash` either: the script then has no terminal for its questions. Each script also explains itself in its header comment.

| Script | For | What it does |
|---|---|---|
| [`proxmox-grub-boot.sh`](#proxmox-grub-bootsh) | a Proxmox VE host (ZFS root, UEFI) | switches the boot loader from systemd-boot to GRUB on every boot disk, and keeps GRUB synced after updates |
| [`samba-setup.sh`](#samba-setupsh) | any Debian machine or LXC | native Samba (SMB) shares, hardened: SMB3 + encryption, no NetBIOS/guests; security fixes via Debian's automatic updates |
| [`nut-setup.sh`](#nut-setupsh) | a Proxmox host or any Debian machine (e.g. an Orange Pi) | sets up NUT, so the machine shuts down cleanly on a power cut. Covers the UPS server, the clients on the same UPS, and monitor-only setups |

---

## proxmox-grub-boot.sh

**Run it** as root on the Proxmox host (the web UI shell works), right after a fresh install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/proxmox-grub-boot.sh)
```

| Option | Effect |
|---|---|
| `--dry-run` | show what would happen; change nothing |
| `--yes` | don't ask before making changes |

After it finishes, reboot and check that `cat /proc/cmdline` starts with `BOOT_IMAGE=`. That prefix means GRUB booted the system; systemd-boot doesn't add it.

### Why

A Proxmox install with ZFS on UEFI boots with **systemd-boot**. At every start, systemd-boot writes and flushes `loader/random-seed` on the boot partition (ESP). Some firmware NVMe drivers hang on that write. This was seen on an ODROID-H4 Ultra (BIOS 1.12) with Samsung PM983 drives, and it shows up as:

```
random-seed.c: Failed to flush random seed file: Time out
boot.c: Error opening root path: Time out
```

When that happens, the machine doesn't boot at all, and it happens at random. Reformatting the drives to 512-byte sectors didn't fix it. A normal **GRUB** boot writes nothing to disk, so switching to GRUB removes the problem. Proxmox supports GRUB on ZFS through `proxmox-boot-tool`.

### What it does

1. **Checks:** root, Proxmox, UEFI boot, ESPs managed by `proxmox-boot-tool`, GRUB packages and `efibootmgr` installed. It warns if a ZFS pool isn't healthy. It saves the firmware boot entries to `/root/efibootmgr-before-grub-<date>.txt`, then asks before changing anything.
2. **Converts** each ESP that is still on systemd-boot, starting with the ones the machine did **not** boot from:
   - `proxmox-boot-tool format <esp> --force`
   - `udevadm settle`
   - `proxmox-boot-tool init <esp> grub`
   - confirms the ESP is registered as GRUB, then runs `proxmox-boot-tool clean`

   If any step fails, it stops. The ESPs it hasn't touched can still boot the machine.
3. **Checks each GRUB ESP** (mounted read-only):
   - every kernel line has `root=ZFS=<pool>/ROOT/… boot=zfs`
   - no `recordfail` or `savedefault` calls, which would make GRUB write at boot
   - `grubenv` is empty
   - a kernel and an initrd are present
   - no `loader/` folder is left over from systemd-boot
4. **Removes firmware entries** that still point at `\EFI\systemd\systemd-bootx64.efi`.
5. **Installs the update hook:**
   - `/usr/local/sbin/pbt-grub-sync`
   - `/etc/apt/apt.conf.d/99-pbt-grub-sync`

   Then it runs `pbt-grub-sync --force` once. That creates one firmware entry per disk, labelled `proxmox (nvme0n1)` and so on, and sets the boot order.

If every ESP already uses GRUB, steps 2–4 have nothing to do and only the hook is (re)installed. That makes it safe to re-run at any time, for example to update the hook.

### The update hook (`pbt-grub-sync`)

Proxmox copies new **kernels** to every ESP by itself. A **GRUB package** update is different: Proxmox doesn't reinstall GRUB onto the ESPs, so they keep running the old GRUB. The apt hook runs `pbt-grub-sync` after every package run, including updates started from the web UI. The script does nothing unless the version of `grub-efi-amd64-bin` changed since the last sync. When it has changed, the script:

- runs `proxmox-boot-tool reinit`, which installs the new GRUB on every ESP;
- re-creates any missing per-disk firmware entries;
- sets the boot order: GRUB on each disk (nvme0 first), then the firmware's own "UEFI OS" fallback entries, then everything else;
- logs to `/var/log/pbt-grub-sync.log` and to syslog (`journalctl -t pbt-grub-sync`).

After an update you'll see `pbt-grub-sync: … done — reboot once when convenient` in the update output. To run it by hand, for example after replacing a disk: `pbt-grub-sync --force`.

### Rules once on GRUB

- **Never** use `proxmox-boot-tool kernel pin --next-boot` or `grub-reboot`. A one-time boot entry makes GRUB write to the ESP at the next boot. A permanent `kernel pin`, or picking an entry in the GRUB menu, is fine.
- **Replacing a boot disk:**
  1. Copy the partition table from the good disk.
  2. Run `proxmox-boot-tool format <esp> --force`, then `udevadm settle`.
  3. Run `proxmox-boot-tool init <esp> grub`. **Don't leave out `grub`**: without it you get systemd-boot back.
  4. Run `proxmox-boot-tool clean`, then `pbt-grub-sync --force`.

  Without the `udevadm settle`, `init` can read the old filesystem UUID, the new ESP isn't registered, and `clean` removes it again.
- `grub-install` reuses the firmware label "proxmox". When it initialises a second ESP, it moves the existing entry. `pbt-grub-sync --force` re-creates the missing entry.
- Avoid a mix of GRUB and systemd-boot ESPs. In that state Proxmox's refresh skips some ESPs.

### Undo

These steps are untested. To go back to systemd-boot, run `proxmox-boot-tool format <esp> --force`, then `udevadm settle`, then `proxmox-boot-tool init <esp>` (without `grub`) on each ESP, then `proxmox-boot-tool clean`. After that, remove the hook:

```bash
rm /usr/local/sbin/pbt-grub-sync /etc/apt/apt.conf.d/99-pbt-grub-sync
rm -r /var/lib/pbt-grub-sync
```

---

## nut-setup.sh

**Run it** as root on each machine on a UPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/nut-setup.sh)
```

It asks for the role and the shutdown policy first. Every answer can also be given as a flag, for a re-run without prompts.

| Role | Policy | Does | Typical use |
|---|---|---|---|
| `server` (USB cable here) | `lb` | at low battery: tells the clients, shuts down, then **cuts the UPS output**. Everything restarts with mains, even if mains returned during the shutdown | the last host on a UPS that also powers network gear or an NVR |
| | `fsd-timer` | after N s on battery: shuts down the clients, then itself, then cuts the output | a UPS that only powers servers |
| | `self-timer` | after N s on battery: shuts down only itself; the UPS keeps running | a heavy host on a shared UPS, with no clients |
| `client` | `lb` | shuts down at low battery, or when the server says so | important hosts that should stay up as long as possible |
| | `timer` | shuts down after N s on battery | big loads that should go first |
| `monitor` | — | only reports the UPS (to clients and Home Assistant); never shuts anything down | a small always-on box on the network UPS |

Flags: `--role`, `--policy`, `--timer <s>`, `--ups <name>`, `--server <ip>` (client), `--password <pw>` (client), `--listen <ip>` (server/monitor, default `0.0.0.0`), `--dry-run` (prints the config it would write, passwords hidden), `--yes`.

**What it sets up:**
- **Detection:** finds the UPS over USB (`nut-scanner`, or by USB vendor ID for APC, Eaton and CyberPower). It names the UPS after its vendor.
- **Restart delays:** for USB-HID UPSes on the `lb` and `fsd-timer` policies, it sets `offdelay`/`ondelay`, which make the UPS cut its output and restore it with mains.
- **Users and passwords:** three users in `upsd.users`:
  - `upsmon`, for the host's own monitor;
  - `client`, for the other hosts on this UPS;
  - `homeassistant`, read-only, for Home Assistant's NUT integration.

  Passwords are generated and printed **once**; save them in your password manager. Re-runs keep them.
- **Timers:** through `upssched`; the action is `upsmon -c fsd` or `shutdown`.
- **Alerts:** each power event (on battery, back online, low battery, shutdown, lost contact, replace battery) is logged (`journalctl -t nut`) and **mailed to root**. On Proxmox, root's mail goes through Datacenter → Notifications, e.g. to Telegram.
- **Checks:** that the UPS answers, that upsd listens where the clients expect it, and that the client's login works. A wrong password stops the script with an error.

**Rules:**
- **Same UPS:** a client is only ever on the **same UPS** as its server. A client on another UPS can lose its server, or the switch in between, at the wrong moment.
- **Re-runs:** run it again to change something. It backs up `/etc/nut` to `/etc/nut.bak-<date>` first.
- **Moving the USB cable:** run it on the new server first, then re-run the old one as a `client`. The script then also stops the old server's NUT services.
- **Test once for real:** unplug the UPS from mains and watch the order. For `lb`, wait until low battery, then plug it back in during the shutdown: everything should come back by itself.

**Tested** by `make test-scripts` (CI too) in Debian systemd containers with a simulated UPS:
- server + client + monitor, including the wrong-password check and re-runs keeping the passwords;
- a power cut: the timer client powers off; at low battery, the server powers off;
- `fsd-timer`: the client goes down first, then the server.

Not covered by the test: real USB detection, cutting a real UPS's output, and the mail.

---

## samba-setup.sh

**Run it** as root in the machine or LXC that has the folders (on a `sudo` machine: `sudo -i` first):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/samba-setup.sh)
```

It asks for a login name, the shares and an optional network limit. Or give them as flags:

```bash
… --user alice --share files=/mnt/files --share media=/mnt/media --share vault=/mnt/vault:ro \
  --allow "192.168.<home-vlan>.0/24 100.64.0.0/10"
```

| Flag | |
|---|---|
| `--user NAME` | the SMB login. A no-login system user plus a Samba password. The password is generated and **printed once**, unless given with `--password` |
| `--share NAME=PATH[:ro]` | repeatable; `:ro` = read-only. Default (interactive): `files`, `media`, `vault:ro` when `/mnt/files`, `/mnt/media`, `/mnt/vault` exist |
| `--owner USER` | everything written over SMB belongs to this user (default `root`, i.e. the LXC's root in an unprivileged LXC), so other tools on the same folders agree on ownership |
| `--allow "CIDR …"` | only these networks may connect (`hosts allow`; localhost always). Default: any |
| `--dry-run` / `--yes` | print the generated `smb.conf` and change nothing / no questions |

**Why native, not a container:** Samba gets regular security fixes. From Debian's package, they install automatically (unattended-upgrades).

**Hardening in the generated `smb.conf`:**
- **SMB3 only** (`server min protocol = SMB3_00`), with **encryption whenever the client supports it** (`smb encrypt = desired`): macOS negotiates SMB 3.1.1 with AES-GCM.
- **Port 445 only:** NetBIOS and `nmbd` off, nothing on 139.
- **No guests, no anonymous listing,** no printers; logs go to the journal.
- **macOS:** `catia fruit streams_xattr`, so Finder tags, metadata and odd file names work. No executable bit on new files (`map archive = no`).

**Re-runs:**
- **Safe:** the old config is kept as `smb.conf.bak-<date>`, the new one must pass `testparm` before it replaces it, and the password stays unless `--password` is given.
- **Checks:** the script ends by checking that `smbd` listens on 445, and by **testing a real login** whenever it knows the password.

**Tested:**
- **On a Debian 13 VM**, from a Mac: mounted over SMB 3.1.1 with encryption required. A Finder tag round-tripped; `vault` refused writes. `--allow` without the Mac's network refused it.
- **On every CI run** in a systemd container (`make test-scripts`): wrong password, anonymous, guest and SMB 2.1 refused; writes owned by the forced owner; read-only share; AES-encrypted SMB3 session; re-run keeps the password; `--allow` blocks.

---

## Adding a script

- Write it in bash with `set -euo pipefail` and a header comment covering why, what it does and usage. It must pass `make test-lint`, which runs shellcheck on every `*.sh`.
- Make it safe to run straight from GitHub: check the preconditions, ask before destructive steps, offer `--dry-run`, and allow re-runs.
- Keep it public: no IPs, hostnames or credentials.
- Add a row to the table above and a section below it.
