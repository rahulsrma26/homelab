# labber

The homelab's service manager: a bash script that sets up fresh LXCs/VMs (`labber setup`) and deploys, updates and monitors the Docker Compose stacks in [`services/`](../services/).

## Getting labber

On a **fresh LXC or VM**, use `setup` (below) — it installs labber along with everything else.

On a machine that's **already set up**:

```bash
curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber | bash -s install
```

Then open a new terminal (or `source ~/.zshrc` / `~/.bashrc`). This installs labber (script + files) in `/usr/local/lib/labber`, linked from `/usr/local/bin/labber`, plus a shell function (needed for `labber <svc> go`) and tab completion in `~/.bashrc` and, if you have one, `~/.zshrc`. `labber update` only touches them when they changed, and then says which file to source. Keep it current with `labber update` — it fetches the script and its files together from the selected source, including changes made without a version bump.

## Repository sources and local testing

The default is this repo's **GitHub `main`**. A source supplies services, tools,
labber itself and setup's `files/`. Forgejo uses ordinary Git URLs; no Forgejo API
token or GitHub mirror is needed. Sources must keep this repo's directory layout.

Choose a source for **one command**, with options before the service/command:

```bash
# Private Forgejo, using SSH configured for the account running labber.
labber --source 'ssh://git@<forgejo-ssh-host>:2222/<owner>/<repo>.git' --ref main ls --remote
labber --source 'https://<forgejo-domain>/<owner>/<repo>.git' --ref main homepage update

# Test your checkout's changes without committing or pushing them.
bash ./labber/labber --source "$PWD" ls --remote
bash ./labber/labber --source "$PWD" homepage update
bash ./labber/labber --source "$PWD" install  # install this labber + files/ locally

# Test committed history instead (branch, tag or full commit SHA).
labber --source "file://$PWD" --ref <branch-tag-or-sha> ls --remote
```

Commands that deploy services still change the installed service under
`/opt/homelab/services` and its running containers. Use a test guest when trying
changes. `ls --remote` only lists the selected source. A local source path names
the Git **working-tree root on the machine running labber**; it can also be a
mounted checkout. A path on your laptop is not automatically available to a guest.
Labber targets Debian/Ubuntu. On macOS, preview your working tree with the same
Debian Docker image used by the tests:

```bash
make test-labber-unit  # builds the test image and checks the working tree
docker run --rm -v "$PWD:/repo:ro" labber-unit \
  bash /repo/labber/labber --source /repo ls --remote
```

That preview does not need a Docker socket inside the container. Use
`make test-labber-setup` for the full setup and service lifecycle in disposable
systemd containers with nested Docker.

Working-tree mode takes a temporary copy of the requested directories. It includes
staged/unstaged edits, deletions and new unignored files, using Git's
[`ls-files --cached --others --exclude-standard`](https://git-scm.com/docs/git-ls-files).
It excludes `.env` even if tracked, ignored untracked files, labber's state and
backup files. It rejects symlinks/submodules in the selected directories. The
source checkout's index and history stay unchanged; installed `.env` and local
edits get the same protection as remote updates. Avoid editing during the copy.
`--ref` applies to Git URLs, including `file://`, rather than working-tree mode.

For a **permanent host setting**, including the daily checker and later updates:

```bash
labber source set 'ssh://git@<forgejo-ssh-host>:2222/<owner>/<repo>.git' main
labber source show
labber homepage update
labber source reset  # remove saved settings; return to GitHub main
```

`source set` saves non-secret `source=` and `ref=` lines in
`/etc/labber/source.conf`, using sudo when needed. With no ref a custom Git source
uses its remote default branch (HEAD); specify `main` for a deployment branch, or
a full SHA to pin a revision. A saved working-tree path is also supported, but the
timer then sees uncommitted edits and needs that path to stay available.

Priority is CLI options → `LABBER_SOURCE`/`LABBER_REF` environment variables → the
host file → GitHub `main`. Selecting a different source clears the lower-priority
ref unless you specify a new one at the same priority. Overrides are not saved by
`install` or `setup`; run `source set` explicitly for subsequent commands/timers.
`source set` and `source reset` can repair a stale checkout path or invalid config.

Use an SSH deploy key or a Git credential helper for private repos, **as the user
running labber** (also the daily timer's `User=`). Keep URL credentials out of this
file and command lines; password-bearing URLs are rejected. Verify SSH host keys
through a trusted channel. Setup runs as root and needs root's Git access for a
private remote, or a readable local checkout. Source choices survive setup's sudo
elevation. The default curl/tar bootstrap still works without Git; custom sources
need Git installed first. The legacy `services/labber` forwarder still bootstraps
from GitHub; use the `labber/labber` entry point for an independent local forge.

`LABBER_REPO`, `LABBER_URL`, `LABBER_SERVICE_BASE` and `LABBER_SOURCE_CONFIG` remain
test-harness hooks; use the supported source options for normal deployments.

## Setting up a fresh LXC or VM

`labber setup` prepares a new Debian/Ubuntu LXC or VM. Run it as root — only `curl` is needed:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup
```

**Unattended** — every answer can be given up front, and `--yes` asks nothing at all (no terminal needed), so a new machine is one pasted line:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup \
  --yes --docker yes --prometheus http://<monitoring>:9090 --with fail2ban
```

| Flag | Answers | Without it, under `--yes` |
|---|---|---|
| `--docker yes\|no` | Docker host? | last answer, else yes |
| `--with` / `--without STEP,…` | the checklist (`update packages locale admin hostname timesync ssh unattended journal swap docker dockerlogs guestagent healthcheck alloy zsh labber fzf nfs fail2ban network`) | the pre-selected steps (optional ones — nfs, fail2ban, swap — off) |
| `--admin NAME` | admin user (VM) | last answer; a new user gets no password (SSH is by key; set one with `passwd` for sudo) |
| `--hostname` / `--timezone` / `--locale` | | unchanged / last answer, else what the machine has (a fresh LXC/VM: `Etc/UTC`) / `en_US.UTF-8` |
| `--ssh-key 'ssh-ed25519 …'` | key, if none is installed | none: password logins stay on |
| `--swap 1\|2\|3` | swap (VM); also checks the swap step | 1 (zram) |
| `--network reservation\|skip` | fixed IP; also checks the network step | last answer, else reservation (changes nothing). A static IP is interactive only |
| `--prometheus URL` / `--loki URL` | Alloy | `--loki` defaults to the Prometheus host, port 3100; neither → the Alloy step is skipped |
| `--virt lxc\|vm` | only if detection fails | last answer |

**`--dry-run`** shows what a run would do — the machine type, Docker yes/no, the checklist, and each answer with where it comes from (your flag, the remembered answer, or the default) — and changes nothing, not even the remembered answers. Check a command line with it, then run it without `--dry-run`.

Without `--yes`, flags answer their questions and the rest is asked as usual. With `--yes` on a VM, key-only SSH isn't test-logged-in first: the Proxmox console is the way back if the key is wrong.

It detects whether it's in an LXC or a VM and asks whether the machine will run **Docker services** — answer no for, say, a plain web server, and the Docker steps are left out (asked on every run, with your last answer as the default; answering no never uninstalls anything). It then shows a checklist with each step's current state and pre-selects what still needs doing. Toggle steps by number, then press Enter.

| Step | LXC | VM | What it does |
|---|---|---|---|
| System update | ✓ | ✓ | `apt full-upgrade` (keeps your modified config files) |
| Base packages | ✓ | ✓ | `curl git sudo htop nano jq tmux rsync ncdu iproute2`; VMs add `smartmontools lm-sensors iotop`; `vainfo` only with a real Intel/AMD GPU |
| Locale | ✓ | ✓ | default `en_US.UTF-8` (generates it, clears installer leftovers like `LANGUAGE`) |
| Admin user | — | ✓ | asks for a name, adds it to `sudo`, copies root's SSH keys |
| Hostname + timezone | ✓ | ✓ | sets them on a VM; for an LXC prints the `pct` command (Proxmox owns the LXC hostname) |
| Time sync | — | ✓ | makes sure `systemd-timesyncd` (or chrony) is running; LXCs use the host's clock |
| SSH: key-only logins | ✓ | ✓ | only once a key is installed (e.g. pasted at `pct create`); root is key-only in an LXC and off in a VM. On a VM you confirm a test login from a second terminal, or it reverts; an LXC can't lock you out (`pct enter` on the host), so it just prints how to undo |
| Automatic security updates | ✓ | ✓ | `unattended-upgrades`, Debian security updates only, no auto-reboot |
| Journal limit | ✓ | ✓ | systemd journal capped at 200 MB |
| Swap | — | optional | asks: **1** zram only — turns off disk swap, so no swap writes to the SSD (also sets `RESUME=none` so boot doesn't wait for the old partition) · **2** zram first, disk swap as overflow · **3** disk swap only. LXC swap is set in Proxmox (`pct set <ID> --swap 0` saves host SSD writes) |
| Docker *(Docker hosts)* | ✓ | ✓ | official Docker repo + compose/buildx; on an LXC, prints the nesting command if Docker can't start |
| Docker log rotation *(Docker hosts)* | ✓ | ✓ | container logs capped at 10 MB × 3 |
| qemu-guest-agent | — | ✓ | plus the `qm set` command to enable it in Proxmox |
| Reboot/update checks | ✓ | ✓ | hourly and after every `apt` run: newer kernel installed (VMs), services on outdated libraries (`needrestart`, list-only), pending security updates. Shown at login, and exported as metrics for alerts |
| Grafana Alloy | ✓ | ✓ | pushes node metrics to Prometheus and the journal to Loki ([`services/monitoring`](../services/monitoring/)); asks for the URLs (or takes `--prometheus` / `--loki`). Unlike the Proxmox hosts (full metrics), guests send only what's useful: VMs ~300 series (CPU, memory, load, disk I/O, real filesystems and NICs, pressure, failed services, health); LXCs even less (failed services, health, `/`, boot time — Proxmox already reports their CPU/memory/network). The config is checked with `alloy fmt` before it's applied. On **Docker hosts** it also sends per-container CPU, memory, network, restarts and OOM kills, plus container logs to Loki (Alloy runs as root there: container metrics need the containerd socket) |
| zsh + powerlevel10k | ✓ | ✓ | for the admin user (root on an LXC): zsh + p10k + autosuggestions + syntax highlighting; uses `tools/zsh/p10k.zsh` if present; labber and fzf work in it. Needs a Nerd Font in your terminal |
| labber | ✓ | ✓ | installed for the admin user (VM) or root (LXC), who also owns `/opt/homelab/services`; on Docker hosts also a daily `labber check-updates` (shown in Grafana) |
| fzf | ✓ | ✓ | from `tools/fzf/install.sh` |
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
labber [--source URL|PATH] [--ref BRANCH|TAG|SHA] [svc] <command>

  [svc] install     deploy a service from the repo (also: deploy)
  [svc] uninstall   stop and remove a service (asks about images, and about the folder + its Docker volumes)
  [svc] start       start containers (docker compose up -d)
  [svc] stop        docker compose stop
  [svc] restart     recreate containers (docker compose up -d --force-recreate)
  [svc] rebuild     pull/build new images, then recreate containers
  [svc] update      pull latest config from repo + rebuild (keeps .env and files you edited)
  [svc] shell       enter a running container shell
  [svc] logs [ctr]  follow the logs (all containers, or one; --tail N / --since 10m too)
  [svc] status      show container status
  [svc] go          cd to service directory (needs the shell function)
  <svc>             show a service's status and commands
  setup             prepare this fresh LXC/VM (see above)
  ls                list services: containers up, health, ports, updates
  ls -r|--remote    list what the repo offers: services (● installed here) and tools
  check-updates     check images and repo config for updates
  clean             remove all unused containers, images, networks, volumes
  tool <name>       run tools/<name>/install.sh from the repo   (tool ls: list them)
  source [show]     show the effective source and ref
  source set URL|PATH [REF]  save a host source for commands and timers (sudo)
  source reset      restore the default GitHub main source (sudo)
  update            system apt update + upgrade + labber self-update
  install           install labber (/usr/local/lib/labber, linked from /usr/local/bin) + shell function
  (no args)         interactive menu
```

Examples: `labber frigate logs` · `labber paperless-ngx restart` · `labber jellyfin go` (changes your shell into `/opt/homelab/services/jellyfin/`).

## What labber checks before starting a service

On every `install`, `start`, `rebuild` and `update`:

- **`.env` values** — keys new in `.env.example` are added to `.env`; placeholders (below) are asked for or generated. If anything is still unset, labber lists it and asks before starting.
- **Credential permissions** — new `.env` files use mode 600; preflight tightens existing files and old `.env.labber-bak` copies too. A direct mount into a different UID (LibreChat) gets mode 640 with the configured data GID, so that container can still read it. Set UID/GID to the intended reader.
- **Ports** — warns if a published port is already used by another container or process.
- **Data folders** — creates missing bind-mount folders owned by `PUID`/`PGID` (or `UID`/`GID`) from `.env`, otherwise by you. Without this, Docker creates them as root and many containers can't write to them. Existing paths are never changed.

**Config files you edited** (frigate's cameras, Prometheus targets…) are never overwritten by `update`. labber remembers each repo file as it installed it (`.labber-base` in the service folder): a file you changed stays as it is, and if the repo changed it too, the repo's version is put next to it as `<file>.labber-new` to compare. Your edits also don't show up as "repo config changed" in `labber ls`. A reinstall (`labber <svc> install` again) does take the repo's version, and keeps yours as `<file>.labber-bak`. `.env.example` and `README.txt` are always replaced (you edit `.env`, which is never touched). If a service has `.env.example` but no `.env`, it's created from it.

Updates pull new images **before** stopping the old containers, so a failed pull or build leaves the service running. Locally built images are built, not pulled.
Docker Compose must support `pull --ignore-buildable`; older versions are refused before stopping containers. Failed image preparation also restores the files changed by an update.
Updates currently merge repository files into the live directory before image preparation. Apps that watch mounted configuration, such as Traefik, can reload those files during preparation; restoring files after a failure does not undo any effects of an intermediate reload. Staging preparation outside live mounts remains a separate improvement.

Files deleted in the repo are removed only when `.labber-base` records them and they are unchanged locally. Edited retired files stay with a warning and continue to appear in update checks until removed manually. Unrelated files and service data are preserved.

**Health check and rollback.** After `install`, `rebuild` and `update`, labber waits for applications to run for 10 s since their last start (a restart or two while a database starts is fine) and pass any healthcheck. Only dependencies declared with `condition: service_completed_successfully` are one-shot jobs: they must finish with exit code 0, and a running job remains pending. All other services must keep running, including those with `restart: "no"`. Standalone batch jobs need a completion dependency to qualify. The overview uses the same rule when counting stopped containers. A crash loop (3+ restarts), a non-zero exit, a dead container, a failed healthcheck or 3 minutes without getting there counts as a failed update, and labber offers to **roll back**: the images the service ran before (kept as `labber-rollback:<id>` until the update is known to be good) and, for `update`, the files it replaced. It asks rather than rolling back by itself, because the new version may already have migrated the app's data, which the old one can't read. Without a terminal it reports the failure, leaves things as they are and exits 1.
Every active Compose service must have a container; an empty list, missing service or Docker query error is a failure. Inactive profiles are excluded. File rollback includes upstream deletions. Failed updates retain their file snapshot and print its path for inspection or recovery; `.env` answers stay in place.
Service commands require Docker Compose, Git and jq; `labber setup` installs these dependencies.

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
| `{{ name \| choice(lan,cf) }}` | one of the listed values (e.g. a service's mode); a wrong answer is asked again | — (skip leaves it unset) |
| `{{ name \| generate([A-Za-z0-9],16) }}` | N random characters from a set (passwords, secrets with a minimum length); typed: at least N | generates |

A typed value that doesn't meet its generator's rule (too short, not hex, …) gets a warning and **use it anyway? [y/N]**: **y** keeps it — for an existing password a restored database or another system expects — and **n** asks again.

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
