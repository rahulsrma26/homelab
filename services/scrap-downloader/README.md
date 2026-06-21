# scrap-downloader

Archival server for images and videos from multiple sites. All traffic routed through Surfshark VPN via gluetun.

## Services

| Service | Port | Notes |
|---|---|---|
| scrap-downloader | 8899 | Web UI |
| gluetun | — | Surfshark WireGuard VPN |

## Setup

```bash
cp .env.example .env
# edit .env with your credentials
docker compose up -d
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8899` | Host port for web UI |
| `APP_PASSWORD` | — | Web UI login password |
| `STORAGE_SECRET` | — | Encryption key for stored data |
| `LOG_LEVEL` | `INFO` | Logging verbosity |
| `WIREGUARD_PRIVATE_KEY` | — | Surfshark WireGuard private key |
| `WIREGUARD_ADDRESSES` | — | WireGuard interface address (e.g. `10.x.x.x/16`) |
| `DOWNLOAD_DIR` | `./downloads` | Downloaded files storage path |
| `PLUGINS_DIR` | `./plugins_data` | Plugin data storage path |
| `DB_PATH` | `./scrap_downloader.db` | SQLite database path |

## VPN

Uses the same Surfshark WireGuard credentials as searxng. Copy from `services/searxng/.env` and update `APP_PASSWORD` and `STORAGE_SECRET`.

`WIREGUARD_ADDRESSES` must include the subnet mask (e.g. `/16`), not just the IP.
