SearXNG — privacy-respecting metasearch engine, routed through AirVPN.

Services:
  searxng-vpn    :5080  Gluetun VPN gateway (all traffic exits via AirVPN)
  searxng               Web UI and API (shares gluetun network)
  searxng-redis         Redis cache (shares gluetun network)

Before deployment:
  .env — fill in all WireGuard credentials from AirVPN config generator
       — set SEARXNG_SECRET to a random string: openssl rand -hex 32
  config/settings.yml — adjust engines/search settings as needed

WireGuard credentials from AirVPN:
  https://airvpn.org/generator/ → WireGuard → select server → download config
  Extract: PrivateKey, PresharedKey, Address

Volumes:
  ./config  — settings.yml and limiter.toml (writable, SearXNG updates it)

Notes:
  - All SearXNG and Redis traffic is routed through gluetun (network_mode: service:gluetun)
  - Redis runs in-memory only (no persistence) — cache is lost on restart
  - secret_key is passed via SEARXNG_SECRET env var, not in settings.yml
  - To change VPN country: edit SERVER_COUNTRIES in docker-compose.yml
