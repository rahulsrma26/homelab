AI-powered tagging and titling for Paperless-ngx.

Services:
  paperless-gpt  :3002  Web UI

Before deployment:
  .env — set PAPERLESS_BASE_URL (URL of your paperless-ngx instance)
         set PAPERLESS_API_TOKEN (from paperless-ngx Settings > API Tokens)
         set LLM_PROVIDER and LLM_MODEL

LLM providers:
  ollama   — local Ollama instance (default)
  openai   — OpenAI or OpenAI-compatible API (e.g. vLLM at /v1)
  anthropic — Anthropic Claude API
