n8n — workflow automation: collects events (alerts, releases), writes digests, wakes the agent.
Docs: https://docs.n8n.io

Services:
  n8n  :5678 (behind the reverse proxy: n8n.home.<domain>)

Data: N8N_DATA (SQLite: workflows, credentials, execution history), owned by PUID:PGID (1000).
Put it on a backed-up dataset. N8N_ENCRYPTION_KEY encrypts the stored credentials: keep it in
the password manager too, or a restore can't read them.

First start: open the editor, create the owner account. Execution history is pruned after
N8N_EXECUTIONS_MAX_AGE_HOURS (14 days).

Behind Traefik: a route to <guest>:5678 (websockets pass by default); N8N_HOST is the name
it's reached at. The guest's firewall: 5678 from the reverse proxy only.

Tests: tests/seed creates the owner and a workflow; tests/check finds it again (CI: across an
upgrade); tests/check --live only asks /healthz/readiness.
