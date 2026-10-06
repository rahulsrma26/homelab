# Rules for this repo

This is a public homelab documentation repository. Follow these rules strictly on every edit.

## Never commit

- Passwords, tokens, or secrets of any kind — use placeholders (see "Secrets format")
- Real IP addresses — use the placeholder format below
- Personal information (full name, email, phone, location)
- `.env` files — `.env.example` with placeholders is fine
- Private hostnames, domain names, or Tailscale node names

## IP address format

Never write real IPs. Use this placeholder format instead:

```
192.168.management.<hostname>    # e.g. 192.168.management.w680
192.168.server.<hostname>
192.168.iot.<hostname>
192.168.<vlan>.<service>         # e.g. 192.168.server.monitoring
```

For ranges: `192.168.management.0/24`

## Secrets format

In config files and examples, use:
- `${ENV_VAR_NAME}` for values read from environment
- `<description>` for values the user must supply in docs and non-`.env` config examples (e.g. `<telegram-bot-token>`)
- In `.env.example` files, Jinja-like placeholders that `labber` fills in on install (it offers to generate the secrets it can, and asks for the rest). No other placeholder style (no `changeme`, no `<...>`, no fake IPs like `192.168.x.y` or domains like `your.domain`) — anything the user must supply is a placeholder:

| Template | Meaning | Enter does |
|---|---|---|
| `{{ name }}` | you must provide it (API tokens, keys from other systems, hosts) | — (skip leaves it unset) |
| `{{ name \| default(8000) }}` | a setting with a sensible default (`default()` = empty) | keeps the default |
| `{{ name \| generate(hex64) }}` | N random hex characters (`openssl rand -hex 32` → `hex64`); typed: exactly N hex | generates |
| `{{ name \| generate(base64_32) }}` | N random bytes, base64-encoded | generates |
| `{{ name \| generate(uuid) }}` | a UUID | generates |
| `{{ name \| generate([A-Za-z0-9],16) }}` | N random characters from a set (passwords, secrets with a minimum length); typed: at least N | generates |

Placeholders can sit anywhere inside a value, e.g. `PAPERLESS_BASE_URL=http://{{ paperless_host }}:{{ paperless_port | default(8000) }}`. A name used several times in one `.env` is asked once and filled in everywhere (e.g. `{{ domain }}`).

Use lowercase snake_case names. Pick the strictest generator the app documents (e.g. LibreChat's `JWT_SECRET` is 32 random bytes as hex → `generate(hex64)`). Never generate values that must match something outside the service (shared passkeys, tokens from other apps) — use `{{ name }}`.

## personal/ directory

Gitignored. Store here anything that doesn't meet the public rules above:
- `.env` files with real credentials
- Docs with real IPs or machine-specific details
- Any other private config

## What belongs here (public)

- Architecture decisions and design docs
- Config file templates with placeholders
- Install scripts (no hardcoded credentials or IPs)
- Network diagrams and service registries with placeholder IPs
- Hardware specs and setup guides
