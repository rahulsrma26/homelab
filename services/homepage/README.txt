Homepage — start page: links, bookmarks and widgets. Docs: https://gethomepage.dev

Services:
  homepage  :3000

Config: services.yaml, bookmarks.yaml, settings.yaml, widgets.yaml in HOMEPAGE_CONFIG
(examples are written on first start; edits apply on reload). Widgets reach each app's
API over the network.

Secrets (widget API keys): put them in .env as HOMEPAGE_VAR_<NAME>=… and write
{{HOMEPAGE_VAR_<NAME>}} in the YAML; the container gets .env (env_file), so the YAML can be
shared or kept in a repo without them. A new or changed one needs labber homepage restart.
