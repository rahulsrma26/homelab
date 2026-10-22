# scripts

Host scripts, one folder each (`<name>/install.sh` plus a `README.md`), run straight from GitHub with one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/<name>/install.sh)
```

**As root.** On a machine where you log in as a normal user with `sudo` (e.g. an Orange Pi), switch to root first with `sudo -i`. `sudo bash <(curl …)` fails with `/dev/fd/63: No such file or directory`, because sudo closes the descriptor the downloaded script is passed through. Don't use `curl … | sudo bash` either: the script then has no terminal for its questions. Each script also explains itself in its header comment and `--help`.

| Script | For | What it does |
|---|---|---|
| [`proxmox-grub-boot/`](proxmox-grub-boot/README.md) | a Proxmox VE host (ZFS root, UEFI) | switches the boot loader from systemd-boot to GRUB on every boot disk, and keeps GRUB synced after updates |
| [`smbmgr/`](smbmgr/README.md) | any Debian machine or LXC | native Samba (SMB) plus `smbmgr`, a tool to add and remove shares for any folder, each with its own read-only and read-write users. Hardened (SMB3 + encryption, no NetBIOS/guests); security fixes via Debian's automatic updates |
| [`nut/`](nut/README.md) | a Proxmox host or any Debian machine (e.g. an Orange Pi) | sets up NUT, so the machine shuts down cleanly on a power cut. Covers the UPS server, the clients on the same UPS, and monitor-only setups |
| [`forgejo-runner/`](forgejo-runner/README.md) | a Debian machine with Docker (a CI VM) | a native Forgejo Actions runner: installs and updates the binary (checksum-verified), its own user and systemd unit; registers it (token typed hidden) |

## Adding a script

- Put it in its own folder: `scripts/<name>/install.sh` (the entry point the one-liner runs) and `scripts/<name>/README.md`. Extra files (like `smbmgr/smbmgr`) go next to them; `install.sh` fetches them from the same branch.
- Write it in bash with `set -euo pipefail` and a header comment covering why, what it does and usage. It must pass `make test-lint`, which runs shellcheck on every script.
- Make it safe to run straight from GitHub: check the preconditions, ask before destructive steps, offer `--dry-run`, and allow re-runs.
- Keep it public: no IPs, hostnames or credentials.
- Add a row to the table above.
