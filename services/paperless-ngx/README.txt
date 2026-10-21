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

AI (PAPERLESS_AI_*, Paperless 3): suggestions for title, date, tags, correspondent and document
  type, and document chat, from any OpenAI-compatible server (PAPERLESS_AI_LLM_ENDPOINT).
  To apply suggestions automatically, add a workflow (trigger: Document Added, action: Apply AI
  Suggestions) — not together with paperless-gpt, which does that after its better OCR.
  Embeddings for chat are computed on this host's CPU.

Optional (paperless_gpt, yes/no at install; COMPOSE_PROFILES in .env):
  paperless-gpt  :3002  OCR by the vision LLM (PAPERLESS_AI_LLM_*): far fewer errors than
                        Tesseract on photos, poor scans and other scripts; pages that already have
                        clean text are kept. Then title, tags, correspondent, date and custom
                        fields. Needs PAPERLESS_API_TOKEN (Paperless → My Profile, after the
                        first start). Paperless still OCRs with Tesseract on consumption (the PDF's
                        text layer); paperless-gpt then replaces the text.
                        A workflow starts it for every new document: Workflows → trigger Document
                        Added → action Assignment, tags paperless-gpt-ocr-auto and paperless-gpt-auto.
                        Prompts in ./paperless-gpt/prompts (missing ones are created from its
                        defaults), settings in its web UI. ocr_prompt.tmpl here asks for a plain,
                        exact transcription: its default (Markdown, Tesseract's text as a
                        reference) read worse (photo: 17 of 24 fields vs 18; scans: CER 10 % vs 0.4 %).
