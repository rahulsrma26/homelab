# immich-public-proxy

Read-only public proxy for Immich shared albums and photos. Sits between the internet and your private Immich instance — only allows through requests for links you have explicitly shared. No API key required, no write access possible.

Source: https://github.com/alangrainger/immich-public-proxy

## Services

| Service | Local Port | Notes |
|---|---|---|
| immich-public-proxy | 3000 | Exposed via Cloudflare tunnel only |

## Setup

```bash
cp .env.example .env
# edit .env with your Immich internal URL and public domain
docker compose up -d
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Host port (bound to 127.0.0.1 only) |
| `IMMICH_URL` | — | Internal URL of your Immich instance |
| `PUBLIC_BASE_URL` | — | Public-facing URL (no trailing slash) |

## Cloudflare Tunnel

Add to `~/.cloudflared/config.yml` on the cloudflare VM:

```yaml
ingress:
  - hostname: photos.yourdomain.com
    service: http://localhost:3000
```

Then route DNS:
```bash
cloudflared tunnel route dns <tunnel-name> photos.yourdomain.com
```

## Security

- Binds to `127.0.0.1` only — not reachable from the network directly
- Stateless and read-only — no credentials stored in the container
- Immich instance URL should be internal only, never exposed publicly
- All public access goes through Cloudflare (WAF, DDoS protection, rate limiting)
