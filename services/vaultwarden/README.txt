Vaultwarden — self-hosted, Bitwarden-compatible password manager.

Services:
  vaultwarden  :PORT (default 8222)  web vault and the API for the Bitwarden apps

Before deployment:
  - VAULTWARDEN_DATA must exist and belong to PUID:PGID (the container doesn't run
    as root): mkdir -p data && chown 1000:1000 data
  - It needs HTTPS in front (a reverse proxy): the apps and browsers refuse plain HTTP.

Moving an existing instance here:
  1. Stop the old container (SQLite keeps recent changes in db.sqlite3-wal; stopping
     writes them into db.sqlite3).
  2. Copy its whole /data folder (db.sqlite3*, rsa_key*, attachments/, sends/,
     config.json if present) into VAULTWARDEN_DATA, then chown -R PUID:PGID.
  3. Keep the same DOMAIN, or every app and extension has to change its server URL
     (and passkey logins to the vault stop working).
  4. Start, log in on the web vault, then on each app.
  An older version's database is upgraded on the first start; going back afterwards
  needs the old copy, not this one.

Backups: VAULTWARDEN_DATA holds everything. Snapshot the folder (SQLite in WAL mode
recovers from a snapshot), or stop the container and copy it. Keep an encrypted
export from the web vault as well (Tools → Export vault).

The admin page is off with ADMIN_TOKEN empty; Vaultwarden then logs a notice about a
"plain text" token at each start, which is harmless.
