# Services

Docker Compose stacks for all self-hosted services. Each service is a self-contained directory with a `docker-compose.yml`, `.env.example`, and a `README.txt` describing what to configure before deployment.

## labber — service manager

`labber` manages the full lifecycle of services on any LXC.

**Install on any LXC:**

```bash
curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/labber \
    -o /usr/local/bin/labber && chmod +x /usr/local/bin/labber
```

**Run interactively (no install needed):**

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
  dir       [svc]   print service directory path
  update            system apt update + upgrade
  (no args)         interactive menu
```

### cd to a service directory

Since a subprocess can't change your shell's directory, add this function to `~/.bashrc`:

```bash
labber() {
  if [[ "$1" == cd ]]; then
    cd "$(/usr/local/bin/labber dir "${@:2}")"
  else
    /usr/local/bin/labber "$@"
  fi
}
```

Then `labber cd frigate` drops you into `/opt/homelab/services/frigate/`.

## Structure

Each service directory contains:

- `docker-compose.yml` — service definition
- `.env.example` — environment variable template (copy to `.env` and fill in values)
- `README.txt` — short summary and list of files to edit before deployment
- `config/` — versioned config files (where applicable)

Services are deployed to `/opt/homelab/services/<service>/` on the target LXC.