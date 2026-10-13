# traefik

Reverse proxy in one of two **modes**, chosen when labber installs it (`traefik_mode` → `COMPOSE_FILE` in `.env`):

| Mode | For | Routes from | TLS | Files |
|---|---|---|---|---|
| **`lan`** | the homelab's own proxy, for LAN + Tailscale clients (an LXC on od01) | files in `dynamic/` (no Docker socket: the apps run in other LXCs/VMs) | one wildcard certificate `*.DOMAIN`, Let's Encrypt DNS-01 at Cloudflare; nothing public | `docker-compose.yml` + `compose.lan.yml` |
| **`cf`** | the **public** entry point behind a Cloudflare Tunnel (w680's hardened VM), for the few public services (e.g. immich-public-proxy) | Docker labels, via a read-only socket proxy | Cloudflare terminates TLS | `docker-compose.yml` + `compose.cf.yml` |

`docker-compose.yml` holds what both share; Compose merges it with the mode's file. To switch modes, change `COMPOSE_FILE` in `.env` and run `labber traefik rebuild`: containers of the other mode are removed.

Upgrading an install from before the split (it had no `.env`): the next `labber traefik update` creates `.env` and asks `traefik_mode`. Answer **`cf`** for the public proxy, then press Enter for the three lan-only values.

---

## lan mode

Every web app gets a name `<name>.<domain>` with HTTPS, from one wildcard certificate. Nothing is exposed to the internet: the certificate comes from Let's Encrypt's DNS-01 challenge at Cloudflare.

| Port | |
|---|---|
| 80 | redirects to 443 |
| 443 | every route; the dashboard at `traefik.<domain>` |

**Before deployment** (`.env`): `DOMAIN`, `ACME_EMAIL`, `CF_DNS_API_TOKEN` (Cloudflare: My Profile → API Tokens → "Edit zone DNS" template, limited to this one zone).

**After deployment:**
1. **DNS:** `*.<domain>` (or each name) → this LXC's IP, in the local DNS (UniFi now, Technitium later). The names need no public DNS records.
2. **Certificate:** the first start requests it (about a minute). Check `labber traefik logs` for errors from the `cloudflare` resolver. It's stored in `letsencrypt/acme.json`; keep that file, because Let's Encrypt limits how often a certificate can be issued.
3. **Routes:** edit `dynamic/routes.yml` and replace the examples with your apps (router + service per app, `entryPoints: [websecure]`). Traefik picks up changes by itself, and labber keeps your edits on update. `dynamic/common.yml` has the shared security headers and `skip-verify`, a transport for backends with self-signed certificates (Proxmox, PBS, TrueNAS).
4. **Firewall:** clients (home VLAN, Tailscale) → this LXC on 80/443; this LXC → each app's port.

| Folder | |
|---|---|
| `dynamic/` | routes and middlewares (yours to edit) |
| `letsencrypt/` | the certificate and ACME account (`acme.json`) |

---

## cf mode

### Architecture

```
cloudflared → localhost:80 → Traefik → proxy network → containers
```

### Setup

Deploy first before any other services:

```bash
docker compose up -d
```

This creates the shared `proxy` Docker network that all other services attach to.

### Adding a new service

1. Add the service to the `proxy` network
2. Use `expose` not `ports`
3. Add Traefik labels:

```yaml
networks:
  - proxy
labels:
  - traefik.enable=true
  - traefik.http.routers.<name>.rule=Host(`service.yourdomain.com`)
  - traefik.http.routers.<name>.entrypoints=web
  - traefik.http.services.<name>.loadbalancer.server.port=<container-port>
  - traefik.http.routers.<name>.middlewares=<name>-headers@docker,<name>-rate-limit@docker
```

### Cloudflare IP ranges

The trusted IP list in the command flags is Cloudflare's published IPv4 ranges. Update if Cloudflare adds new ranges:
https://www.cloudflare.com/ips-v4/
