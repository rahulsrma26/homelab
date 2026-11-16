SearXNG — privacy-respecting metasearch engine, routed through AirVPN.

Services:
  searxng-vpn    :5080  Gluetun VPN gateway (all traffic exits via AirVPN)
  searxng               Web UI and API (shares gluetun network)
  searxng-redis         Redis cache (shares gluetun network)

With scraper=firecrawl (COMPOSE_FILE, asked at install; none adds nothing):
  firecrawl      :3002  Firecrawl API: /v2/scrape (URL → Markdown), /v2/search (through this SearXNG)
  firecrawl-playwright  headless Chromium for pages that need JavaScript
  firecrawl-redis       cache and rate limits (in memory)
  firecrawl-rabbitmq    the job queue's messages
  firecrawl-postgres    the job queue (FIRECRAWL_DB_DIR; jobs only, nothing to keep)

Before deployment:
  .env — fill in all WireGuard credentials from AirVPN config generator
       — set SEARXNG_SECRET to a random string: openssl rand -hex 32
  config/settings.yml — adjust engines/search settings as needed

WireGuard credentials from AirVPN:
  https://airvpn.org/generator/ → WireGuard → select server → download config
  Extract: PrivateKey, PresharedKey, Address

Volumes:
  ./config  — settings.yml and limiter.toml (writable, SearXNG updates it)

Notes:
  - All SearXNG and Redis traffic is routed through gluetun (network_mode: service:gluetun)
  - Redis runs in-memory only (no persistence) — cache is lost on restart
  - secret_key is passed via SEARXNG_SECRET env var, not in settings.yml
  - To change VPN country: edit SERVER_COUNTRIES in docker-compose.yml

Firecrawl (scraper=firecrawl):
  - For LibreChat's web search (searchProvider searxng, scraperProvider firecrawl, firecrawlApiUrl
    http://host:3002, any non-empty firecrawlApiKey) and n8n (its Firecrawl node, a custom URL).
  - No API key (USE_DB_AUTHENTICATION=false): allow only its clients to reach FIRECRAWL_PORT.
  - Searches go through the VPN (SearXNG); page fetches leave directly, not through the VPN.
  - Memory (measured): ~2.6 GB idle, ~3.1 GB with 8 pages at once (8 scrapes in 3 s);
    FIRECRAWL_MEMORY / FIRECRAWL_BROWSER_MEMORY cap the API and Chromium (4g / 2g).
  - Check: tests/check-firecrawl (scrapes example.com, searches through SearXNG).
