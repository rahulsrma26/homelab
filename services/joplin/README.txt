Joplin Server — sync server for the Joplin note apps. All notes live in its Postgres.

Services:
  joplin     :22300  sync API + admin web UI (/login)
  joplin-db          Postgres 16 (not published: only Joplin talks to it)

Before deployment:
  .env — JOPLIN_BASE_URL (what the apps use), JOPLIN_DB_PASSWORD

Restoring a dump (pg_dumpall of Postgres 16):
  1. .env: JOPLIN_DB_PASSWORD = the old password, JOPLIN_VERSION = the old version
  2. docker compose up -d joplin-db     (wait until healthy)
  3. gunzip -c joplin.sql.gz | docker exec -i joplin-db psql -U joplin -d postgres
  4. labber joplin start; log in at JOPLIN_BASE_URL/login; let one app sync
  5. JOPLIN_VERSION=latest, then labber joplin update
The dump must come from Postgres 16 (the major version must match).
