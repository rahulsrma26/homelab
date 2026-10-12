# scripts

One-off host scripts, each meant to be run straight from GitHub with a single command. Each script also explains itself in its header comment.

| Script | For | What it does |
|---|---|---|
| [`proxmox-grub-boot.sh`](#proxmox-grub-bootsh) | a Proxmox VE host (ZFS root, UEFI) | switches the boot loader from systemd-boot to GRUB on every boot disk, and keeps GRUB synced after updates |

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

## Adding a script

- Write it in bash with `set -euo pipefail` and a header comment covering why, what it does and usage. It must pass `make test-lint`, which runs shellcheck on every `*.sh`.
- Make it safe to run straight from GitHub: check the preconditions, ask before destructive steps, offer `--dry-run`, and allow re-runs.
- Keep it public: no IPs, hostnames or credentials.
- Add a row to the table above and a section below it.
