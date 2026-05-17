# Services

Docker Compose stacks for all self-hosted services. Each service is a self-contained directory with a `docker-compose.yml`, `.env.example`, and a `README.txt` describing what to configure before deployment.

## labber — service manager

`labber` manages the full lifecycle of services on any LXC.

**Install on any LXC** (installs binary + adds shell function to `~/.bashrc`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber) self-install
source ~/.bashrc
```

**Run interactively without installing:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber)
```

### Commands

```
labber [command] [service]

  install   [svc]   install a service from the repo
  uninstall [svc]   stop and remove a service
  start     [svc]   docker compose start
  stop      [svc]   docker compose stop
  restart   [svc]   docker compose restart
  rebuild   [svc]   full rebuild: down + system prune + pull + up
  shell     [svc]   enter a running container shell
  logs      [svc]   follow docker compose logs
  status    [svc]   show container status
  go        [svc]   cd to service directory (requires self-install)
  update            system apt update + upgrade + labber self-update
  self-install      install binary + shell function to ~/.bashrc
  (no args)         interactive menu
```

`labber go frigate` changes your shell into `/opt/homelab/services/frigate/`. It works via a shell function that `self-install` writes to `~/.bashrc` automatically.

## Structure

Each service directory contains:

- `docker-compose.yml` — service definition
- `.env.example` — environment variable template (copy to `.env` and fill in values)
- `README.txt` — short summary and list of files to edit before deployment
- `config/` — versioned config files (where applicable)

Services are deployed to `/opt/homelab/services/<service>/` on the target LXC.