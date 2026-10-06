# labber

The homelab's service manager: a bash script that sets up fresh LXCs/VMs (`labber setup`) and deploys, updates and monitors the Docker Compose stacks in [`services/`](../services/).

## Getting labber

On a **fresh LXC or VM**, use `setup` (below) — it installs labber along with everything else.

On a machine that's **already set up**:

```bash
curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber | bash -s install
source ~/.bashrc
```

This installs labber (script + files) in `/usr/local/lib/labber`, linked from `/usr/local/bin/labber`, plus a shell function (needed for `labber <svc> go`) and tab completion in `~/.bashrc`. Keep it current with `labber update` — it downloads the repo's tarball (~100 KB), so the script and its files always match.

## Setting up a fresh LXC or VM

`labber setup` prepares a new Debian/Ubuntu LXC or VM. Run it as root — only `curl` is needed:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup
```

It detects whether it's in an LXC or a VM and asks whether the machine will run **Docker services** — answer no for, say, a plain web server, and the Docker steps are left out (asked on every run, with your last answer as the default; answering no never uninstalls anything). It then shows a checklist with each step's current state and pre-selects what still needs doing. Toggle steps by number, then press Enter.

| Step | LXC | VM | What it does |
|---|---|---|---|
| System update | ✓ | ✓ | `apt full-upgrade` (keeps your modified config files) |
| Base packages | ✓ | ✓ | `curl git sudo htop nano jq tmux rsync ncdu`; VMs add `smartmontools lm-sensors iotop`; `vainfo` only with a real Intel/AMD GPU |
| Locale | ✓ | ✓ | default `en_US.UTF-8` (generates it, clears installer leftovers like `LANGUAGE`) |
| Admin user | — | ✓ | asks for a name, adds it to `sudo`, copies root's SSH keys |
| Hostname + timezone | ✓ | ✓ | sets them on a VM; for an LXC prints the `pct` command (Proxmox owns the LXC hostname) |
| Time sync | — | ✓ | makes sure `systemd-timesyncd` (or chrony) is running; LXCs use the host's clock |
| SSH: key-only logins | ✓ | ✓ | only once a key is installed; root is key-only in an LXC and off in a VM; you confirm a test login from a second terminal, or it reverts |
| Automatic security updates | ✓ | ✓ | `unattended-upgrades`, Debian security updates only, no auto-reboot |
| Journal limit | ✓ | ✓ | systemd journal capped at 200 MB |
| Swap | — | optional | asks: **1** zram only — turns off disk swap, so no swap writes to the SSD (also sets `RESUME=none` so boot doesn't wait for the old partition) · **2** zram first, disk swap as overflow · **3** disk swap only. LXC swap is set in Proxmox (`pct set <ID> --swap 0` saves host SSD writes) |
| Docker *(Docker hosts)* | ✓ | ✓ | official Docker repo + compose/buildx; on an LXC, prints the nesting command if Docker can't start |
| Docker log rotation *(Docker hosts)* | ✓ | ✓ | container logs capped at 10 MB × 3 |
| qemu-guest-agent | — | ✓ | plus the `qm set` command to enable it in Proxmox |
| Reboot/update checks | ✓ | ✓ | hourly and after every `apt` run: newer kernel installed (VMs), services on outdated libraries (`needrestart`, list-only), pending security updates. Shown at login, and exported as metrics for alerts |
| Grafana Alloy | ✓ | ✓ | pushes node metrics to Prometheus and the journal to Loki ([`services/monitoring`](../services/monitoring/)); asks for the URLs. Unlike the Proxmox hosts (full metrics), guests send only what's useful: VMs ~300 series (CPU, memory, load, disk I/O, real filesystems and NICs, pressure, failed services, health); LXCs even less (failed services, health, `/`, boot time — Proxmox already reports their CPU/memory/network). The config is checked with `alloy fmt` before it's applied. On **Docker hosts** it also sends per-container CPU, memory, network, restarts and OOM kills, plus container logs to Loki (Alloy runs as root there: container metrics need the containerd socket) |
| zsh + powerlevel10k | ✓ | ✓ | for the admin user (root on an LXC): zsh + p10k + autosuggestions + syntax highlighting; uses `tools/zsh/p10k.zsh` if present; labber and fzf work in it. Needs a Nerd Font in your terminal |
| labber | ✓ | ✓ | installed for the admin user (VM) or root (LXC), who also owns `/opt/homelab/services`; on Docker hosts also a daily `labber check-updates` (shown in Grafana) |
| fzf | ✓ | ✓ | from `tools/fzf.sh` |
| NFS client / fail2ban | optional | optional | off by default |
| Network: fixed IP | ✓ | ✓ | see below |

**Fixed IP** — three choices:

1. **UniFi DHCP reservation** (recommended): nothing changes on the machine; setup shows the MAC to reserve.
2. **Static IP** — on a VM, setup writes the config (`ifupdown` or `netplan`), applies it in the background and **rolls back after 2 minutes** unless you connect to the new address and confirm:
   ```bash
   ssh <admin>@<new-ip>
   sudo labber setup --confirm-ip
   ```
   On an LXC, setup prints the `pct set` command instead (Proxmox owns the LXC's network config).
3. Skip.

Everything that has to happen on the Proxmox host (hostname, LXC static IP, nesting, guest agent) is collected and printed at the end with `<CTID>`/`<VMID>` placeholders. Steps check before acting, so `labber setup` can be re-run any time — it only does what's missing. On a VM, run it from the Proxmox console the first time, so a lost SSH session never matters.

## Commands

```
labber [svc] <command>

  [svc] install     deploy a service from the repo (also: deploy)
  [svc] uninstall   stop and remove a service (asks about images, and about the folder + its Docker volumes)
  [svc] start       start containers (docker compose up -d)
  [svc] stop        docker compose stop
  [svc] restart     recreate containers (docker compose up -d --force-recreate)
  [svc] rebuild     pull/build new images, then recreate containers
  [svc] update      pull latest config from repo + rebuild (preserves .env)
  [svc] shell       enter a running container shell
  [svc] logs        follow docker compose logs
  [svc] status      show container status
  [svc] go          cd to service directory (needs the shell function)
  <svc>             show a service's status and commands
  setup             prepare this fresh LXC/VM (see above)
  ls                list services: containers up, health, ports, updates
  check-updates     check images and repo config for updates
  clean             remove all unused containers, images, networks, volumes
  tool <name>       run an install script from tools/   (tool ls: list them)
  update            system apt update + upgrade + labber self-update
  install           install labber (/usr/local/lib/labber, linked from /usr/local/bin) + shell function
  (no args)         interactive menu
```

Examples: `labber frigate logs` · `labber paperless-ngx restart` · `labber jellyfin go` (changes your shell into `/opt/homelab/services/jellyfin/`).

## What labber checks before starting a service

On every `install`, `start`, `rebuild` and `update`:

- **`.env` values** — keys new in `.env.example` are added to `.env`; placeholders (below) are asked for or generated. If anything is still unset, labber lists it and asks before starting.
- **Ports** — warns if a published port is already used by another container or process.
- **Data folders** — creates missing bind-mount folders owned by `PUID`/`PGID` (or `UID`/`GID`) from `.env`, otherwise by you. Without this, Docker creates them as root and many containers can't write to them. Existing paths are never changed.

Updates pull new images **before** stopping the old containers, so a failed pull or build leaves the service running. Locally built images are built, not pulled.

Without a terminal (cron, scripts), labber never prompts: it reports what's wrong and doesn't start the service.

## `.env` templates

Values in a service's `.env.example` (in [`services/`](../services/)) that labber fills in on install (and on update, for newly added keys):

| Template | Meaning | Enter does |
|---|---|---|
| `{{ name }}` | you must provide it (API tokens, keys from other systems, hosts) | — (skip leaves it unset) |
| `{{ name \| default(8000) }}` | a setting with a sensible default (`default()` = empty) | keeps the default |
| `{{ name \| generate(hex64) }}` | N random hex characters (`openssl rand -hex 32` → `hex64`); typed: exactly N hex | generates |
| `{{ name \| generate(base64_32) }}` | N random bytes, base64-encoded | generates |
| `{{ name \| generate(uuid) }}` | a UUID | generates |
| `{{ name \| generate([A-Za-z0-9],16) }}` | N random characters from a set (passwords, secrets with a minimum length); typed: at least N | generates |

Placeholders can sit anywhere inside a value, e.g. `PAPERLESS_BASE_URL=http://{{ paperless_host }}:{{ paperless_port | default(8000) }}`. A name used several times in one `.env` is asked once and filled in everywhere (e.g. `{{ domain }}`).

labber first asks once whether to generate all the secrets (it lists them); answer no to go through them one by one. Values only you can provide are asked one by one; secrets are typed hidden and checked against their rule. Anything left unset is listed before starting, and labber asks before starting anyway.

## Updates

`labber ls` shows each service's containers up, health, published ports, and whether an update is available:

```
  ● jellyfin        1/1 up   :8096         up to date
  ● librechat       3/4 up   :3080,:3003   1 unhealthy   new image
```

Update status comes from `labber check-updates`, which compares each pulled image with its registry and each service's files with the repo. Run it weekly from cron:

```bash
0 6 * * 1  /usr/local/bin/labber check-updates >/dev/null 2>&1
```

Then apply with `labber <svc> update` (config + images) or `labber <svc> rebuild` (images only).

## How labber is built

```
labber/
  labber                 the script
  files/                 config files labber installs (copied as they are, or with @NAME@ filled in)
    alloy/base.alloy     Grafana Alloy config for every guest: node metrics + journal
    alloy/docker.alloy   appended on Docker hosts: container metrics + container logs
    health-check.sh      /usr/local/sbin/labber-health-check (reboot / restart / updates metrics)
    motd-health.sh       /etc/update-motd.d/95-labber-health (login message)
```

### Installed layout

`/usr/local/lib/labber/` holds a copy of this folder; `/usr/local/bin/labber` is a link to the script in it. `labber install`, `labber update` and the setup step all download the repo's tarball and swap the whole folder, so the script and its files always come from the same commit.

Run without an installed copy (`bash <(curl …/labber/labber) setup` on a fresh machine), labber has no `files/` next to it: setup downloads them to a temp folder for that run.

### Editing files

- A value labber fills in is written `@NAME@` and passed by the code that installs the file (`labber_file alloy/base.alloy VIRT=vm …`). Values go in literally, so they may hold any character. In `.alloy` files, keep each `@NAME@` inside a string, so the file stays valid Alloy on its own.
- What stays in the script: small snippets built from runtime values (sshd config, systemd units naming the user or path, netplan/ifupdown, `.bashrc` blocks). A file for those would need more templating than it saves.
- Any edit here (script or files) bumps `VERSION` in `labber` (a Claude Code hook does it once per commit), so `labber update` picks it up.
- Tests: `make test-labber-unit` checks every `@NAME@` is filled in and runs the real `alloy fmt` on these files and on the configs generated from them. See [tests/labber/](../tests/labber/).

### services/labber (pre-4.0 installs)

Before 4.0, labber was a single file at `services/labber`. That path is now a forwarder: old installs self-update to it, and its next run moves the install to `/usr/local/lib/labber`. Keep it until no machine runs a pre-4.0 labber.

## Tests

labber has unit tests (run in a container) and integration tests (run on a throwaway VM) — see [tests/labber/README.md](../tests/labber/README.md).
