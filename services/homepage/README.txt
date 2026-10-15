Homepage — start page: links, bookmarks and live widgets for every app.

Services:
  homepage  :3000  the page (behind Traefik: e.g. https://home.<domain>)

Before deployment (.env):
  HOMEPAGE_ALLOWED_HOSTS  every name you open it at, e.g. home.<domain>,<lxc-ip>:3000
  HOMEPAGE_CONFIG/IMAGES  where its config and images live (default: this folder)
  PUID/PGID               the owner of its files (0 when the folder belongs to root)

Config: services.yaml (the app tiles), bookmarks.yaml, settings.yaml, widgets.yaml in
HOMEPAGE_CONFIG. The first start writes examples there; edit them and reload the page
(no restart needed). Docs: https://gethomepage.dev

Widgets talk to each app's API over the network, so they work across LXCs/VMs. Container
status from other machines needs a read-only docker-socket-proxy there.

Moving from another machine: copy the old config/ and images/ into HOMEPAGE_CONFIG and
HOMEPAGE_IMAGES before the first start.
