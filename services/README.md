# Services

Docker Compose stacks for all self-hosted services. Each service is a self-contained directory with a `docker-compose.yml`, `.env.example`, and a `README.txt` describing what to configure before deployment.

They're deployed and managed with **labber** — how to get it, set up a fresh LXC/VM, and every command: [labber/README.md](../labber/README.md). In short:

```bash
labber <svc> install      # deploy from the repo: fills in .env, checks ports and data folders
labber ls                 # what's running, and which services have updates
labber <svc> update       # new config from the repo + new images, keeping .env
```

## Adding a service

Each service directory contains:

- `docker-compose.yml` — service definition
- `.env.example` — every variable the compose file uses, with `{{ … }}` templates ([labber's `.env` templates](../labber/README.md#env-templates)) for secrets and anything machine-specific (hosts, domains). Pick the strictest generator the app documents, and use `{{ name }}` for anything that must match a value elsewhere.
- `README.txt` — short summary and list of files to edit before deployment (shown during install)
- `config/` — versioned config files (where applicable)

Services are deployed to `/opt/homelab/services/<service>/` on the target machine. Never commit a `.env`.

### Variants and optional containers (no extra service folders)

labber runs `docker compose` inside the service folder, so Compose reads two settings from `.env`. A `{{ … | choice(…) }}` template turns them into an install question:

| Need | How | Example |
|---|---|---|
| **The same app in different setups** | a shared `docker-compose.yml` plus one `compose.<variant>.yml` per variant; `.env.example`: `COMPOSE_FILE=docker-compose.yml:compose.{{ mode \| choice(a,b) }}.yml` | `traefik`: `lan` (homelab proxy) or `cf` (public, behind a Cloudflare Tunnel) |
| **Optional containers** | `profiles: [<name>]` on the container; `.env.example`: `COMPOSE_PROFILES={{ name \| default() }}` | a local ML worker that only some installs run |

- **Switching later:** change the value in `.env`, then run `labber <svc> rebuild`. It removes the other variant's containers (`down --remove-orphans`).
- **Variables:** the repo lint checks `${VARS}` in `compose.*.yml` files as well.
- **Settings only one variant uses:** give them `default()`, so the other variant can just press Enter.

## Monitoring

How VMs, LXCs and containers are watched (details in `monitoring/README.txt`):

| What | By |
|---|---|
| Every VM/LXC: up, CPU, memory, disk, network (seen from Proxmox) | pve-exporter in `monitoring` |
| Inside each guest: disk, failed services, reboot needed, stuck updates, logs | Alloy, installed by `labber setup` |
| Containers on Docker hosts: CPU, memory, restarts, OOM kills, logs; available updates | Alloy + `labber check-updates` |
| Does each service actually answer? | Uptime Kuma (`uptime-kuma`), on a different machine than `monitoring` so they watch each other |
| Dashboards | Grafana → Homelab folder: Guests, Containers, Logs, Proxmox |
| Alerts | Alertmanager → Telegram (rules tested with `make test-monitoring`) |
