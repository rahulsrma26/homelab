# immich-public-proxy

Read-only public proxy for Immich shared albums and photos. Sits between the internet and your private Immich instance — only allows through requests for links you have explicitly shared. No API key required, no write access possible.

Source: https://github.com/alangrainger/immich-public-proxy

## How it's reached

On the public VM, behind Traefik in `cf` mode ([traefik](../traefik/README.md)):

```
visitor → Cloudflare → cloudflared (on the VM) → localhost:80 → Traefik → immich-public-proxy:3000 → Immich
```

The container publishes no port: Traefik finds it on the `proxy` network by its labels (`homelab.exposure=public`, host `PUBLIC_HOSTNAME`), with security headers and a per-visitor rate limit (`CF-Connecting-IP`).

## Setup

1. Traefik in `cf` mode on the same VM (it creates the `proxy` network).
2. `labber immich-public-proxy install`.
3. Cloudflare: the tunnel's public hostname for `PUBLIC_HOSTNAME` → `http://localhost:80` (Traefik, not the container).
4. Firewall: this VM → Immich's API port only ([guides/public-tunnel-vm.md](../../guides/public-tunnel-vm.md)).

## Configuration

| Variable | Description |
|---|---|
| `IMMICH_URL` | Internal URL of your Immich instance, e.g. `http://<immich-host>:2283` (by IP: its resolver is picky) |
| `PUBLIC_BASE_URL` | Public URL of the share links, no trailing slash |
| `PUBLIC_HOSTNAME` | The host name Traefik routes to it (the same name, without `https://`) |

Downloads and full-size zoom are on (`CONFIG` in `docker-compose.yml`).

## Security

- No published port; only Traefik on the `proxy` network reaches it
- Stateless and read-only (read-only root, no capabilities): no credentials stored
- Immich itself stays internal: the proxy asks it only for shared links
- All public access goes through Cloudflare (WAF, DDoS protection, rate limiting) and Traefik's rate limit
