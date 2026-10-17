# traefik

Reverse proxy in one of two **modes**, chosen when labber installs it (`traefik_mode` → `COMPOSE_FILE` in `.env`):

| Mode | For | Routes from | TLS | Files |
|---|---|---|---|---|
| **`lan`** | the homelab's own proxy, for LAN + Tailscale clients | files in `dynamic/` (no Docker socket: the apps run in other LXCs/VMs) | one wildcard certificate `*.DOMAIN`, Let's Encrypt DNS-01 at Cloudflare; nothing public | `docker-compose.yml` + `compose.lan.yml` |
| **`cf`** | the **public** entry point behind a Cloudflare Tunnel, for the few public services | Docker labels, via a read-only socket proxy | Cloudflare terminates TLS | `docker-compose.yml` + `compose.cf.yml` |

`docker-compose.yml` holds what both share; Compose merges it with the mode's file. To switch modes, change `COMPOSE_FILE` in `.env` and run `labber traefik rebuild`: containers of the other mode are removed.

Upgrading an install from before the split (it had no `.env`): the next `labber traefik update` creates `.env` and asks `traefik_mode`. Answer **`cf`** for the public proxy, then press Enter for the three lan-only values.

---

## lan mode

Every web app gets a name `<name>.home.<domain>` with HTTPS, from one wildcard certificate. Nothing is exposed to the internet: the certificate comes from Let's Encrypt's DNS-01 challenge at Cloudflare.

**Why a sub-domain** (`DOMAIN` = `home.<domain>`, not `<domain>`): public services under the same domain (e.g. behind a Cloudflare Tunnel in `cf` mode) keep their public DNS records. A local wildcard for the whole domain would send those names to this proxy, which has no route for them. With `home.`, one local wildcard serves every homelab app and touches nothing public.

| Port | |
|---|---|
| 80 | redirects to 443 |
| 443 | every route; the dashboard at `traefik.home.<domain>` (user `admin`, `DASHBOARD_PASSWORD` from `.env`) |

**Before deployment** (`.env`): `DOMAIN` (e.g. `home.<domain>`), `ACME_EMAIL`, `CF_DNS_API_TOKEN` (Cloudflare: My Profile → API Tokens → "Edit zone DNS" template, limited to your domain's zone; it covers the sub-domain too). `DASHBOARD_PASSWORD` is generated.

**After deployment:**
1. **DNS:** one local record `*.home.<domain>` → this LXC's IP, in UniFi (Technitium later). If your UniFi can't do wildcards, one record per name. No public DNS records are needed — except, with a public wildcard `*.<domain>`, a record at `home.<domain>` (e.g. a TXT), so that wildcard doesn't cover `*.home.<domain>`. Check from a client: `nslookup traefik.home.<domain>` returns this LXC's IP.
2. **Certificate:** the first start requests it (about a minute). Check `labber traefik logs` for errors from the `cloudflare` resolver. It's stored in `letsencrypt/acme.json`; keep that file, because Let's Encrypt limits how often a certificate can be issued.
3. **Routes:** edit `dynamic/routes.yml` and replace the examples with your apps (router + service per app, `entryPoints: [websecure]`). Traefik picks up changes by itself, and labber keeps your edits on update. `dynamic/common.yml` has the shared security headers (`secure-headers`, or `secure-headers-sameorigin` for apps that embed their own pages), the dashboard login, and `skip-verify`, a transport for backends with self-signed certificates (Proxmox, PBS, TrueNAS).
4. **Firewall:** clients (home VLAN, Tailscale) → this LXC on 80/443; this LXC → each app's port.
5. **Remote (Tailscale):** split DNS for `home.<domain>` only → the local DNS server, plus a route to this LXC (subnet router or exit node).

**When the internet is down**, everything keeps working: the names resolve locally and the certificate is stored here (renewal needs the internet, but starts 30 days before expiry). Unless a client asks someone else than the local DNS:
- **a second, public DNS server** on the client (or in DHCP): it may get asked instead and doesn't know `home.<domain>`. Give clients the local DNS only;
- **encrypted DNS that bypasses it:** browser "Secure DNS" (Chrome, Firefox, Edge), Android "Private DNS", **iCloud Private Relay** on Apple devices. Turn them off on the home network, or exclude the domain.

| Folder | |
|---|---|
| `dynamic/` | routes and middlewares (yours to edit) |
| `letsencrypt/` | the certificate and ACME account (`acme.json`) |
| `auth/` | the dashboard's hashed password, written at each start from `.env` |

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
3. Add Traefik labels, including `homelab.exposure=public` (without it, Traefik ignores the container):

```yaml
networks:
  - proxy
labels:
  - traefik.enable=true
  - homelab.exposure=public
  - traefik.http.routers.<name>.rule=Host(`service.yourdomain.com`)
  - traefik.http.routers.<name>.entrypoints=web
  - traefik.http.services.<name>.loadbalancer.server.port=<container-port>
  - traefik.http.routers.<name>.middlewares=<name>-headers@docker,<name>-rate-limit@docker
```

### Forwarded headers and visitor IPs

cloudflared runs on the VM and reaches Traefik through Docker's gateway, so Traefik trusts forwarded headers from Docker's private ranges (port 80 is published on `127.0.0.1` only). Apps then see `X-Forwarded-Proto: https` and the visitor's IP in `X-Forwarded-For`; `CF-Connecting-IP` always holds the visitor's IP. Rate limits must count per visitor: `ratelimit.sourcecriterion.requestheadername=CF-Connecting-IP`, otherwise every visitor shares one limit (all requests come from the gateway). The access log keeps `CF-Connecting-IP` and `CF-Ray`.
