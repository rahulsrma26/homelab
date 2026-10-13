Paperless-ngx document management system.

Services:
  webserver  :8075  Paperless web UI and API
  broker            Redis (cache only, no backup needed)
  gotenberg         PDF/Office document conversion
  tika              Document text extraction

Before deployment:
  .env — PAPERLESS_URL (the address you open it at), PAPERLESS_DIR (data + media + export,
         kept together), CONSUME_DIR; the secret key and admin password are generated

Consume directory:
  Drop documents into consume/ — Paperless auto-imports them.
  Point a scanner or watched folder here.

Backup:
  Back up: data/ and media/
  Skip:    redisdata volume (Redis cache, auto-rebuilt)

Optional (yes/no at install, COMPOSE_PROFILES in .env; change later and `labber paperless-ngx rebuild`):
  paperless-gpt  :3002  LLM-generated titles/tags/correspondents and LLM OCR. Needs
                        PAPERLESS_API_TOKEN and an OpenAI-compatible LLM (OPENAI_BASE_URL).
                        Prompts in ./paperless-gpt/prompts (copy old ones there).
  paperless-ai   :3003  automatic tagging + chat with documents; configured in its web UI.
