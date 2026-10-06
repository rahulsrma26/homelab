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

## Monitoring

How VMs, LXCs and containers are watched (details in `monitoring/README.txt`):

| What | By |
|---|---|
| Every VM/LXC: up, CPU, memory, disk, network (seen from Proxmox) | pve-exporter in `monitoring` |
| Inside each guest: disk, failed services, reboot needed, stuck updates, logs | Alloy, installed by `labber setup` |
| Containers on Docker hosts: CPU, memory, restarts, OOM kills, logs; available updates | Alloy + `labber check-updates` |
| Does each service actually answer? | Uptime Kuma, part of `monitoring` |
| Dashboards | Grafana → Homelab folder: Guests, Containers, Logs, Proxmox |
| Alerts | Alertmanager → Telegram (rules tested with `make test-monitoring`) |
