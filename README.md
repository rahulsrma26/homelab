# homelab

[![ci](https://github.com/rahulsrma26/homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/rahulsrma26/homelab/actions/workflows/ci.yml)
[![labber](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Frahulsrma26%2Fhomelab%2Frefs%2Fheads%2Fmain%2Flabber%2Flabber&search=VERSION%3D%22(%5B%5E%22%5D%2B)%22&replace=v%241&label=labber&color=blue)](labber/)

Config, scripts and docs for a Proxmox-based homelab: Docker Compose stacks for self-hosted services, **labber** to deploy and run them, and monitoring for every machine, VM, LXC and container.

## Layout

| Path | What's in it |
|---|---|
| [`labber/`](labber/) | **labber**, the bash tool that sets up fresh LXCs/VMs and installs, updates and monitors the services |
| [`services/`](services/) | one folder per service: `docker-compose.yml`, `.env.example` (with templates labber fills in), `README.txt` |
| [`scripts/`](scripts/) | host scripts, one folder each (`scripts/<name>/install.sh`), run with one command from GitHub: Proxmox systemd-boot → GRUB, NUT UPS shutdown, Samba + `smbmgr`. See [scripts/README.md](scripts/README.md) |
| [`tests/`](tests/) | labber unit tests (in Docker) and integration tests (on a throwaway VM); Prometheus alert-rule tests |
| [`tools/`](tools/) | tools for a login shell, one folder each (`tools/<name>/install.sh`, run by `labber tool <name>`), plus config files labber setup uses |

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
| Access & security | Authelia + LLDAP (SSO), Vaultwarden, Traefik (LAN reverse proxy, or the public entry via Cloudflare Tunnel), Nginx Proxy Manager (being retired) |
| Monitoring | Prometheus, Grafana, Loki, Alertmanager (→ Telegram), InfluxDB, pve-exporter; Uptime Kuma (separate) |
| Media & files | Jellyfin, Immich, Immich public proxy, Navidrome, SoulSync (+ slskd), FileBrowser Quantum, MeTube |
| Documents | Paperless-ngx, Paperless-GPT |
| AI | llama.cpp (CUDA, plus a TurboQuant build), LibreChat, voice assistant agent |
| Cameras | Frigate |
| Utilities | Homepage, Joplin Server, it-tools, omni-tools, BentoPDF, LibreSpeed, SearXNG, Termix |

Details and conventions for adding a service: [services/README.md](services/README.md).

## Tests

```bash
make test-labber-unit                                  # labber unit tests + Alloy config checks (Docker)
make test-labber-setup                                 # labber setup from scratch in systemd containers (LXC and VM paths)
LABBER_TEST_HOST=user@vm make test-labber-vm           # labber integration tests on a test VM
make test-monitoring                                   # Prometheus rules + Alertmanager config
make test-scripts                                      # scripts/ end-to-end (NUT with a simulated UPS)
make test-lint                                         # repo rules (templates, compose vars, private IPs, keys, personal details) + shellcheck
make hooks                                             # once per clone: the same rules on every git push
make ci                                                # everything CI runs on each push
```

## Branches

- **`dev`:** where changes go. Every push runs CI.
- **`main`:** the **stable** branch, which machines install and update from (`labber update`, `labber check-updates`, the one-liners). Only CI moves it, fast-forwarding to a `dev` commit once **every** CI job has passed, so a broken build never reaches a machine.
- **The pre-push hook** refuses direct pushes to `main`.

## Conventions

This repo is public. No secrets, real IPs, private hostnames or personal details. Once per clone, run **`make hooks`**: every `git push` then runs the repo lint on the working tree **and on the pushed commits**, and refuses the push if anything slips through. Put your own words (domain, names, e-mail) in `personal/lint-denylist.txt` (gitignored); the hook checks those too. Addresses are written as `192.168.<vlan>.<host>`, and secrets as `{{ name | generate(…) }}` templates in `.env.example`. Anything private lives in gitignored folders. See [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
