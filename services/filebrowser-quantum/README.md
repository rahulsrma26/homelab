# filebrowser-quantum

Web-based file browser. Which folders it shows depends on the machine, chosen at install (`filebrowser_host` → `COMPOSE_FILE` in `.env`):

| Variant | Folders | Sources (config) |
|---|---|---|
| `w680` | TrueNAS datasets via NFS (`/mnt/media`, `/mnt/extra`) + the local pool (`/mysatapool/zdata`) | `data/config.yaml` |
| `od01` | `/mnt/common`, `/mnt/media`, `/mnt/vault` (read-only) | `config.od01.yaml` |
| `ms01` | `/mnt/extra` (the scratch share, never backed up) | `config.ms01.yaml` |

**od01 settings** (`config.od01.yaml`): a new user gets no permissions; grant each one what they need (Settings → Users: e.g. edit on `common` and `media`). `vault` is read-only for everyone. The admin keeps full access; existing users keep what they have. Don't name a source `files`: Filebrowser's URLs start with `/files/` ([#3095](https://github.com/gtsteffaniak/filebrowser/issues/3095)).

An install from before the variants existed is asked `filebrowser_host` on its next `labber update`: answer `w680` there.

Source: https://github.com/gtsteffaniak/filebrowser

## Services

| Service | Port | Notes |
|---|---|---|
| filebrowser | 8448 | Web UI |

## Setup

`labber filebrowser-quantum install`: it asks the variant (`filebrowser_host`). The first start prints the generated `admin` password: `labber filebrowser-quantum logs | grep -i password`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8448` | Host port for the web UI |
| `COMPOSE_FILE` | (the variant) | `docker-compose.yml` plus `compose.<variant>.yml` |

The folders are fixed in each variant's compose file (`compose.w680.yml`, `compose.od01.yml`); another machine is another variant file. Filebrowser's own settings and database live in `./data`.

## NFS mounts (w680 variant)

Both TrueNAS datasets are mounted via NFS in `/etc/fstab` on the host VM; the container bind-mounts them at `/srv/media` and `/srv/extra`.
