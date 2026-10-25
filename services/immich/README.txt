Immich — photo and video library, with Immich Kiosk (a slideshow page).

Services:
  immich-server            :2283  Web UI, API, mobile apps
  database, redis                 Postgres (pinned image) and Valkey
  optional — each a yes/no question at install (COMPOSE_PROFILES in .env):
  immich-machine-learning         faces, smart search, duplicates (OpenVINO on the iGPU)
  immich-kiosk             :3502  slideshow page
  immichframe              :3503  digital photo frame page (set it up at :3503/admin)
  immich-power-tools       :3504  bulk tools (merge people, fix dates/locations, …)

Changing the optional containers later: edit COMPOSE_PROFILES in .env (e.g. ml-yes →
ml-no), then `labber immich rebuild` — containers that are no longer wanted are removed.

Before deployment:
  .env — UPLOAD_LOCATION (the library), DB_PASSWORD, the optional containers;
         their API keys (Kiosk, Power Tools) come from Immich → Account Settings → API Keys
  iGPU: /dev/dri must exist (LXC: pass /dev/dri/renderD128 with the render group's gid)

The library is mounted at /data. The database stores every file as /data/library/…,
/data/thumbs/… — never change that container path.

Restoring a backup (e.g. moving Immich to a new machine):
  1. Copy the library into UPLOAD_LOCATION (library/, upload/, thumbs/, encoded-video/,
     profile/, backups/). Keep owners and times (rsync -aHAX).
  2. .env: add IMMICH_VERSION = the version in the dump's name (immich-db-backup-…-v2.0.1-…),
     DB_PASSWORD = the old one (the dump resets the database role to it),
     KIOSK_IMMICH_API_KEY = the old key.
  3. Start only the database:   docker compose up -d database   (wait ~10 s)
  4. Restore (Immich's documented way):
       gunzip --stdout <UPLOAD_LOCATION>/backups/immich-db-backup-<newest>.sql.gz \
         | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
         | docker exec -i immich_postgres psql --dbname=postgres --username=immich
  5. Start everything (labber immich start), log in, check albums, people, shared links.
  6. Then upgrade: delete the IMMICH_VERSION line from .env, labber immich update. Within a major
     version (v3) every update is safe; for a new major version, read its breaking changes
     (GitHub discussions, label changelog:breaking-change) and the extras' requirements
     (Kiosk ≥ Immich v3.2, ImmichFrame ≥ v3). Update the mobile apps first.
  Restore the database and library as a pair from one point in time: the dump inside
  the library you restored, not a database backup from another day.

Machine learning: Admin → Machine Learning → URL can list several servers (tried in
order). Put a faster one (e.g. a GPU VM's immich-machine-learning) first and the local
one (immich_ml = yes) second, so smart search still works when the other is off. With
no ML at all, smart search, face recognition and duplicate detection don't run.

Power Tools reads Immich's database directly (DB_* from .env) and needs its own API key.
