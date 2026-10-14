# smbmgr

Native Samba (SMB) file shares on Debian (e.g. in an LXC), managed with one command. Any folder or subfolder can become a share. **Each share gets its own users:** `<share>-ro` reads, `<share>-rw` reads and writes. So each app or device gets exactly the access it needs, and a leaked password only exposes one share at one level.

| File | |
|---|---|
| `install.sh` | installs Samba, the hardened global config and `smbmgr`. Re-run to upgrade; keeps all state. `--uninstall` removes it all again |
| `smbmgr` | the tool, installed to `/usr/local/sbin/smbmgr` |

## Install

As root (on a `sudo` machine: `sudo -i` first):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/smbmgr/install.sh)
```

The first run asks who should own written files (default `root`) and which networks may connect (default: any). Or pass `--owner USER`, `--allow "CIDR …"` / `--any`, `--yes`.

- **Upgrading:** re-running `install.sh` replaces `smbmgr` with the newest version from `main`, keeping every share, user and password.
- **Uninstalling:** `install.sh --uninstall` removes Samba, `smbmgr`, its state and the users it made. The shared folders stay.
- **Why native, not a container:** Samba gets regular security fixes. From Debian's package, they install automatically (unattended-upgrades).

## Use

```bash
smbmgr add docs /mnt/files/docs          # → docs-ro + docs-rw, random passwords, printed
smbmgr add photos /mnt/vault/photos      # folder on a read-only mount → only photos-ro
smbmgr list                              # shares, folders, mode, users, networks
smbmgr show [docs | docs-rw]             # the stored passwords again
smbmgr reset docs-rw                     # a new password for one user
smbmgr remove docs                       # share gone; its users disabled (--purge: deleted, asks first;
                                         #   also works later, for a removed share's disabled users)
smbmgr move docs /mnt/files/papers       # a new folder; users and passwords stay
smbmgr refresh [docs]                    # the mount became writable / read-only → -rw added / disabled

smbmgr user add alice --rw docs,files --ro photos    # a personal account; password asked; prints smb://alice@<ip>/
smbmgr user set alice --rw docs --ro photos         # change its shares
smbmgr user passwd alice | user remove alice | user list
smbmgr user set alice                               # refused: give shares, or user remove

smbmgr allow "192.168.<home-vlan>.0/24 100.64.0.0/10"   # only these networks (--any: all)
smbmgr owner root                        # owner of everything written over SMB
smbmgr check                             # config, smbd on 445, folders, no hand edits, every user logs in
smbmgr apply                             # regenerate smb.conf from the state
smbmgr add --help                        # any command: just its usage
```

Options: `--yes` skips the questions before deleting (scripts without a terminal never get asked); `--no-check` skips the SMB self-test after `add`, `move` and `refresh`.

**Personal accounts** are for Finder: a Mac logs in to a server as **one user at a time**, so it can't mount `docs` as `docs-rw` and `files` as `files-rw` together. A personal account reaches several shares under one login. Its password is **asked** (or `--password-stdin`, at least 12 characters) and never stored.

**Nested shares** are allowed (`files` and `files/docs`). `docs`'s users only see `docs`, but `files`'s users can of course also reach `docs/` through `files`.

## How it works

- **State** is kept in `/etc/smbmgr/` (mode 700, root only):
  - `shares` and `users`: tab-separated lists;
  - `config`: owner and networks;
  - `accounts`: the system users smbmgr created;
  - `secrets` (mode 600): the share users' passwords, so `show` can print them again. Anyone with root on this machine can read them, but root there owns the data anyway.
- **`smb.conf` is generated** from the state after every change:
  - checked with `testparm`, the old one backed up (the newest 10 are kept), swapped in atomically;
  - Samba is **reloaded, not restarted**, so open connections stay.
  - `check` spots hand edits; `apply` puts it back.
- **Each change is all or nothing:** the state is snapshotted first. If the command fails, smbmgr restores it, deletes the users it just created, puts changed passwords back, and regenerates `smb.conf`. A lock keeps two runs from overlapping.
- **Self-test:** after `add`, `move` or `refresh`, each of the share's users is tested for real over SMB (`-ro` reads and can't write, `-rw` writes). If one fails, the command fails, rolls back and says why. The test file is hidden and has no document or photo extension (`.smbmgr-check-<pid>.tmp`), so apps watching the folder (Paperless, Immich) skip it; it's deleted at once. Passwords reach `smbclient` through a root-only file, never on the command line (`ps`).
- **Users:** each user is a Samba user backed by a **no-login system user**. On every share, everyone works **as one owner**: reads don't depend on file modes (a `-ro` user can read a `600` file), and writes are forced to that owner (default `root`, i.e. the LXC's root in an unprivileged LXC), so other tools on the same folders (e.g. Filebrowser) agree on ownership. Changing the owner only affects new files (smbmgr says how to `chown` the old ones).
- **Only its own accounts:** smbmgr records the system users it creates and never uses or deletes any other, so a name like `root` or `backup` is refused, not taken over.
- **Paths Samba can't hold** are refused with a clear message: a `%` (Samba expands `%d`, `%u`, …), a trailing space, control characters. Spaces and accents are fine. Share names `global`, `homes` and `printers` are reserved.
- **Interrupted** (Ctrl-C, `kill`, a dropped SSH session): rolled back like a failure.
- **No system folders:** `/`, `/etc`, `/root`, `/boot`, `/usr`, `/proc`, `/sys`, `/dev`, `/run` and anything containing `/etc/smbmgr` or Samba's password database can't be shared.
- **Audit trail:** every change is logged to the journal: `journalctl -t smbmgr`.

**Security settings** (the `[global]` section):

| | |
|---|---|
| Protocol | **SMB3 only**, with **encryption whenever the client supports it** (macOS: SMB 3.1.1 with AES-GCM) |
| Ports | 445 only: NetBIOS and `nmbd` off, nothing on 139 |
| Access | no guests, no anonymous listing; `hosts allow` when networks are set (localhost always) |
| Off | printers and the spool service; logs go to the journal |
| macOS | `catia fruit streams_xattr`: Finder tags, metadata and odd file names work; no executable bit on new files |

## Tested

- **Test VM (Debian 13) + a Mac:**
  - **Shares:** a share on a read-only mount (no `-rw` user created) and nested shares, with each user kept to its own share.
  - **Personal account:** it writes rw shares only, and its password isn't stored.
  - **Lifecycle:** `reset`, `remove` (disable / `--purge`; personal accounts updated), user `set`/`passwd`, and `check` spotting a hand edit and a missing folder. A re-run of `install.sh` kept everything.
  - **In a terminal:** the questions before `remove --purge` and `install.sh --uninstall` ("n" cancels, nothing changed); refusing `root` and `/etc`; per-command `--help`.
  - **Corner cases:** Ctrl-C in the middle of `add` (rolled back, nothing left over); two runs at once (the second waits); an upgrade with an SMB session open (the session stays); the installer asking again after a mistyped owner or network; a folder with spaces and accents reached over the network; `check` on a share with 20,000 files (under a second).
  - **From the Mac:** two shares mounted as one personal account over SMB 3.1.1 with encryption required; writing to the read-only share was refused.
- **Every CI run** (`make test-scripts` → `tests/scripts/run-smbmgr.sh`, in a systemd container):
  - the same checks;
  - the refusals (wrong password, anonymous, guest, SMB 2.1) and an AES-encrypted SMB3 session;
  - a failed command leaving the state unchanged; a failed self-test rolling back the state, `smb.conf` and the new users;
  - existing system accounts never taken over or deleted; system folders refused;
  - `refresh` as a mount turns writable and back; `move` keeping users and passwords;
  - bad input refused with a message, never silently: reserved names, `%` and trailing-space paths, a group's name, a flag without its value, extra arguments, invalid CIDRs, a password prompt without a terminal;
  - a `-ro` user reading a `600` file; purging a removed share's leftover users;
  - `check` spotting a disabled user and a stale password;
  - `allow` blocking an unlisted network;
  - `--uninstall` removing only what it made.
