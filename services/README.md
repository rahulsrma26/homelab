# Services

Docker Compose stacks for all self-hosted services. Each service is a self-contained directory with a `docker-compose.yml`, `.env.example`, and a `README.txt` describing what to configure before deployment.

## labber — service manager

`labber` manages the full lifecycle of services on any LXC.

**Install on any LXC** (installs binary + adds shell function to `~/.bashrc`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber) install
source ~/.bashrc
```

**Run interactively without installing:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber)
```

### Commands

```
labber [svc] <command>

  [svc] uninstall   stop and remove a service
  [svc] start       docker compose start
  [svc] stop        docker compose stop
  [svc] restart     docker compose restart
  [svc] rebuild     full rebuild: down + system prune + pull + up
  [svc] shell       enter a running container shell
  [svc] logs        follow docker compose logs
  [svc] status      show container status
  [svc] go          cd to service directory (requires install)
  ls                list installed services and status
  clean             remove all unused containers, images, networks, volumes
  update            system apt update + upgrade + labber self-update
  install           install labber binary + shell function to ~/.bashrc
  (no args)         interactive menu (includes service deploy)
```

`labber frigate logs` follows logs for the frigate service.
`labber paperless-ngx restart` recreates paperless-ngx containers.
`labber go frigate` changes your shell into `/opt/homelab/services/frigate/` — works via a shell function that `labber install` writes to `~/.bashrc`.

## Structure

Each service directory contains:

- `docker-compose.yml` — service definition
- `.env.example` — environment variable template (copy to `.env` and fill in values)
- `README.txt` — short summary and list of files to edit before deployment
- `config/` — versioned config files (where applicable)

Services are deployed to `/opt/homelab/services/<service>/` on the target LXC.
