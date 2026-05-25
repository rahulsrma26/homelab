Paperless-ngx document management system.

Services:
  webserver  :8075  Paperless web UI and API
  broker            Redis (cache only, no backup needed)
  gotenberg         PDF/Office document conversion
  tika              Document text extraction

Before deployment:
  .env — set PAPERLESS_SECRET_KEY (generate with: openssl rand -hex 32)
         set PAPERLESS_ADMIN_USER / PAPERLESS_ADMIN_PASSWORD
         set PAPERLESS_URL to your external URL

Consume directory:
  Drop documents into consume/ — Paperless auto-imports them.
  Point a scanner or watched folder here.

Backup:
  Back up: data/ and media/
  Skip:    redisdata volume (Redis cache, auto-rebuilt)
