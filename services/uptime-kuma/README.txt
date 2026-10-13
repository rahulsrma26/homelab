Uptime Kuma — checks from the outside that each service actually answers, and alerts via Telegram.

Kept apart from services/monitoring on purpose: run it on a different machine than the
monitoring stack, so the two watch each other (Prometheus' HostNotReporting covers Kuma's
host; Kuma checks Grafana/Prometheus/Home Assistant and the hosts). It alerts Telegram
directly, not through Alertmanager, so it still works when the monitoring host is down.

Services:
  uptime-kuma  :3001  Web UI, status pages, monitors

Volumes:
  ./data  — monitors, notification settings and history (SQLite). Writes on every check:
            on an SD card, use a high-endurance card.

Once after deployment (http://<host>:3001):
  1. Create the admin account (strong password: the UI can see your whole network layout).
  2. Settings → Notifications → add Telegram (same bot and chat as monitoring's .env),
     tick "Default enabled".
  3. Add a monitor per thing to check, interval 60s:
       HTTP(s)   web UIs and APIs, e.g. http://192.168.server.jellyfin:8096,
                 Proxmox https://192.168.management.<host>:8006 (ignore TLS errors)
       HTTP      Tang servers: http://192.168.management.<tang>/adv
       TCP Port  services without a web page, e.g. NUT <host>:3493

Moving it (e.g. from the old monitoring stack): stop the container, copy its data
(the old named volume uptime-kuma-data, or ./data) into ./data on the new host, start it.
