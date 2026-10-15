# filebrowser-quantum

Web-based file browser. Which folders it shows depends on the machine, chosen at install (`filebrowser_host` → `COMPOSE_FILE` in `.env`):

| Variant | Folders | Sources (config) |
|---|---|---|
| `w680` | TrueNAS datasets via NFS (`/mnt/media`, `/mnt/extra`) + the local pool (`/mysatapool/zdata`) | `data/config.yaml` |
| `od01` | FilesOd01's mounts: `/mnt/common`, `/mnt/media`, `/mnt/vault` (**read-only**: Immich and Paperless own those files) | `config.od01.yaml` |

**od01 settings** (`config.od01.yaml`): new users can create, edit and delete in `common` and `media`; `vault` is read-only in Filebrowser too. Users that already exist keep their rights: change them in Settings → User Management. (Don't name a source `files`: Filebrowser's own URLs start with `/files/`, and editing or opening folders 2+ levels deep then fails with "403 source name not found", [issue #3095](https://github.com/gtsteffaniak/filebrowser/issues/3095).)

An install from before the variants existed is asked `filebrowser_host` on its next `labber update`: answer `w680` there.

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
