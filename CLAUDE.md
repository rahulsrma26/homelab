# Rules for this repo

This is a public homelab documentation repository. Follow these rules strictly on every edit.

## Never commit

- Passwords, tokens, or secrets of any kind — use `changeme` or `<description>` placeholders
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
- `changeme` in `.env.example` files
- `<description>` for values the user must supply (e.g. `<telegram-bot-token>`)

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
