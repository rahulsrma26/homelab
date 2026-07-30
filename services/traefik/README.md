# traefik

Reverse proxy that sits between cloudflared and all services. Routes by hostname, applies rate limiting and security headers, and only accepts traffic from Cloudflare IP ranges.

## Architecture

```
cloudflared → localhost:80 → Traefik → proxy network → containers
```

## Setup

Deploy first before any other services:

```bash
docker compose up -d
```

This creates the shared `proxy` Docker network that all other services attach to.

## Adding a new service

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

## Cloudflare IP ranges

The trusted IP list in the command flags is Cloudflare's published IPv4 ranges. Update if Cloudflare adds new ranges:
https://www.cloudflare.com/ips-v4/
