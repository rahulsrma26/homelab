# Services

Docker Compose stacks for all self-hosted services. Each service is a self-contained directory with a `docker-compose.yml`, `.env.example`, and a `README.txt` describing what to configure before deployment.

Services are managed with **labber** (`services/labber`), a single bash script that sets up fresh machines and deploys, updates and monitors these services.

## Getting labber

On a **fresh LXC or VM**, use `setup` (below) — it installs labber along with everything else.

On a machine that's **already set up**:

```bash
curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber | bash -s install
source ~/.bashrc
```

This installs `/usr/local/bin/labber`, a shell function (needed for `labber <svc> go`) and tab completion in `~/.bashrc`. Keep it current with `labber update`.

## Setting up a fresh LXC or VM

`labber setup` prepares a new Debian/Ubuntu LXC or VM. Run it as root — only `curl` is needed:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber) setup
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
| zram swap | — | optional | compressed swap in RAM (50%, used before disk swap); pre-ticked on VMs with ≤ 4 GB RAM |
| Docker *(Docker hosts)* | ✓ | ✓ | official Docker repo + compose/buildx; on an LXC, prints the nesting command if Docker can't start |
| Docker log rotation *(Docker hosts)* | ✓ | ✓ | container logs capped at 10 MB × 3 |
| qemu-guest-agent | — | ✓ | plus the `qm set` command to enable it in Proxmox |
| Reboot/update checks | ✓ | ✓ | hourly and after every `apt` run: newer kernel installed (VMs), services on outdated libraries (`needrestart`, list-only), pending security updates. Shown at login, and exported as metrics for alerts |
| Grafana Alloy | ✓ | ✓ | pushes node metrics to Prometheus and the journal to Loki, like the Proxmox hosts (`services/monitoring`); asks for the URLs |
| zsh + powerlevel10k | ✓ | ✓ | for the admin user (root on an LXC): zsh + p10k + autosuggestions + syntax highlighting; uses `tools/zsh/p10k.zsh` if present; labber and fzf work in it. Needs a Nerd Font in your terminal |
| labber | ✓ | ✓ | installed for the admin user (VM) or root (LXC), who also owns `/opt/homelab/services` |
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
  [svc] uninstall   stop and remove a service (asks about images and the folder)
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
  install           install labber to /usr/local/bin + shell function
  (no args)         interactive menu
```

Examples: `labber frigate logs` · `labber paperless-ngx restart` · `labber jellyfin go` (changes your shell into `/opt/homelab/services/jellyfin/`).

## What labber checks before starting a service

On every `install`, `start`, `rebuild` and `update`:

- **`.env` values** — keys new in `.env.example` are added to `.env`; placeholders (below) are generated or asked for. If anything is still unset, labber lists it and asks before starting.
- **Ports** — warns if a published port is already used by another container or process.
- **Data folders** — creates missing bind-mount folders owned by `PUID`/`PGID` (or `UID`/`GID`) from `.env`, otherwise by you. Without this, Docker creates them as root and many containers can't write to them. Existing paths are never changed.

Updates pull new images **before** stopping the old containers, so a failed pull or build leaves the service running. Locally built images are built, not pulled.

Without a terminal (cron, scripts), labber never prompts: it reports what's wrong and doesn't start the service.

## `.env` placeholders

Values in a service's `.env.example` that labber fills in on install:

| Placeholder | Meaning | Autofill |
|---|---|---|
| `_changeme_` | you must provide it (API tokens, keys from other systems) | — asks |
| `_changeme_min_N_` | any value of at least N characters | N random letters/digits |
| `_changeme_hex_N_` | exactly N hex characters (`openssl rand -hex 32` → `_changeme_hex_64_`) | random hex |
| `_changeme_b64_N_` | base64 of N random bytes | random |
| `_changeme_md5_` / `_changeme_sha256_` | same as `_changeme_hex_32_` / `_changeme_hex_64_` | random hex |
| `_changeme_uuid_` | a UUID | random UUID |
| `changeme`, `<...>` | older style — you must provide it | — asks |

On install labber asks once whether to generate everything it can, then asks only for values that must come from you (secrets are typed hidden, and checked against their rule).

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

## Adding a service

Each service directory contains:

- `docker-compose.yml` — service definition
- `.env.example` — every variable the compose file uses, with placeholders for secrets (see above). Pick the strictest rule the app documents, and use `_changeme_` for anything that must match a value elsewhere.
- `README.txt` — short summary and list of files to edit before deployment (shown during install)
- `config/` — versioned config files (where applicable)

Services are deployed to `/opt/homelab/services/<service>/` on the target machine. Never commit a `.env`.

## Tests

labber has unit tests (run in a container) and integration tests (run on a throwaway VM) — see [tests/labber/README.md](../tests/labber/README.md).
