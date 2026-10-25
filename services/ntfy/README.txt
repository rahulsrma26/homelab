ntfy — a self-hosted inbox for machine messages: alerts, test results, notices. Topics are
read in the web app (NTFY_BASE_URL) or in the ntfy phone app, which only notifies you if you
subscribe. Nothing works without a login.

Services:
  ntfy       :PORT (default 8091)  web app and API (put HTTPS in front, e.g. Traefik)
  ntfy-auth  runs once at each start: hashes the passwords into config/server.yml

Access (all topics):
  admin      you, web login with NTFY_ADMIN_PASSWORD
  publisher  send only, with NTFY_PUBLISH_TOKEN:
               curl -H "Authorization: Bearer $NTFY_PUBLISH_TOKEN" -d "text" https://<ntfy>/<topic>
  reader     read only, with NTFY_READ_TOKEN:
               curl -H "Authorization: Bearer $NTFY_READ_TOKEN" "https://<ntfy>/<topic>/json?poll=1"

Alertmanager: a webhook receiver to https://<ntfy>/<topic>?template=alertmanager with the
publish token as a bearer token (see services/monitoring, ALERT_TARGET=ntfy).

Data: data/ holds the message cache (NTFY_KEEP) and the user database, rebuilt from .env at
each start. Nothing worth backing up.
