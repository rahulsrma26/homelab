# homelab

Config, scripts and docs for a Proxmox-based homelab: Docker Compose stacks for self-hosted services, **labber** to deploy and run them, and monitoring for every machine, VM, LXC and container.

## Layout

| Path | What's in it |
|---|---|
| [`labber/`](labber/) | **labber**, the bash tool that sets up fresh LXCs/VMs and installs, updates and monitors the services |
| [`services/`](services/) | one folder per service: `docker-compose.yml`, `.env.example` (with templates labber fills in), `README.txt` |
| [`tests/`](tests/) | labber unit tests (in Docker) and integration tests (on a throwaway VM); Prometheus alert-rule tests |
| [`tools/`](tools/) | install scripts and dotfiles (`labber tool <name>`) |

## Quick start

On a fresh Debian/Ubuntu LXC or VM, as root:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup
```

Then deploy a service:

```bash
labber jellyfin install    # asks for or generates the .env values, checks ports and data folders
labber ls                  # what's running, and which services have updates
```

Full guide: [labber/README.md](labber/README.md).

## Services

| Area | Services |
|---|---|
| Access & security | Authelia + LLDAP (SSO), Vaultwarden, Nginx Proxy Manager, Traefik |
| Monitoring | Prometheus, Grafana, Loki, Alertmanager (→ Telegram), InfluxDB, pve-exporter, Uptime Kuma |
| Media & files | Jellyfin, Immich public proxy, FileBrowser Quantum, MeTube |
| Documents | Paperless-ngx, Paperless-GPT |
| AI | llama.cpp (CUDA, plus a TurboQuant build), LibreChat, voice assistant agent |
| Cameras | Frigate |
| Utilities | Homepage, Joplin Server, it-tools, Stirling PDF, OpenSpeedTest, SearXNG, Termix |

Details and conventions for adding a service: [services/README.md](services/README.md).

## Tests

```bash
make test-labber-unit                                  # labber unit tests + Alloy config checks (Docker)
make test-labber-setup                                 # labber setup from scratch in a systemd container (LXC path)
LABBER_TEST_HOST=user@vm make test-labber-vm           # labber integration tests on a test VM
make test-monitoring                                   # Prometheus rules + Alertmanager config
make test-lint                                         # repo rules (templates, compose vars, no private IPs) + shellcheck
make ci                                                # everything CI runs on each push
```

## Conventions

This repo is public. No secrets, real IPs, private hostnames or personal details. Addresses are written as `192.168.<vlan>.<host>`, and secrets as `{{ name | generate(…) }}` templates in `.env.example`. Anything private lives in gitignored folders. See [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
