# filebrowser-quantum

Web-based file browser for accessing TrueNAS datasets mounted on the host via NFS.

Source: https://github.com/gtsteffaniak/filebrowser

## Services

| Service | Port | Notes |
|---|---|---|
| filebrowser | 8448 | Web UI |

## Setup

```bash
cp .env.example .env
# edit .env if mount paths differ
docker compose up -d
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8448` | Host port for web UI |
| `MEDIA_DIR` | `/mnt/media` | Host path to media NFS mount |
| `EXTRA_DIR` | `/mnt/extra` | Host path to extra NFS mount |
| `DATA_DIR` | `./data` | FileBrowser config and database |

## NFS Mounts

Both datasets are mounted from TrueNAS via NFS and defined in `/etc/fstab` on the host VM. The container bind-mounts them at `/srv/media` and `/srv/extra`.
