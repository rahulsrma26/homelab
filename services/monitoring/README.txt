Central observability stack — metrics, logs, dashboards, and alerts.

Services:
  grafana       :3000  Dashboards and visualisation
  prometheus    :9090  Metrics storage (90d retention, 20GB cap)
  loki          :3100  Log aggregation (30d retention)
  influxdb      :8086  Time-series storage for Home Assistant (365d retention)
  alertmanager  :9093  Alert routing to Telegram
  pve-exporter  :9221  Proxmox API metrics for Prometheus
  uptime-kuma   :3001  Checks that each service actually answers; alerts via Telegram

Before deployment:
  .env
  config/prometheus/prometheus.yml

After deployment:
  Run utils/install-exporters.sh on each Proxmox host to install Alloy + smartctl_exporter.
  LXCs/VMs: `labber setup` installs Alloy with the same layout (job "guest-node-exporters",
  label kind=lxc|vm) plus a health check that exports labber_reboot_required,
  labber_restart_required_services and labber_security_updates_pending.

Alerts (config/prometheus/alert.rules.yml, tested by tests/monitoring/run.sh):
  HostDown             a target Prometheus scrapes is down
  HostNotReporting     a host/guest that pushes via Alloy stopped sending metrics
  SystemdUnitFailed    a systemd service is failed for 15 min
  RebootRequired       newer kernel installed for over a day
  ServicesNeedRestart  services on outdated libraries for over a day
  SecurityUpdatesStuck security updates pending for a week
  ContainerRestarting  a container restarted 3+ times in 15 min (Docker hosts)
  ContainerGone        a container that was running stopped or was removed
  ContainerOOMKilled   a container ran out of memory
  ServiceUpdateAvailable  labber check-updates found an update (info: weekly note)

Dashboards (Grafana → Homelab folder, provisioned from config/grafana/provisioning/dashboards):
  Guests       every VM/LXC set up by labber: uptime, CPU, memory, disk, failed services, reboot, updates
  Containers   per-container CPU, memory, network, restarts, OOM kills; service updates
  Logs         journal + container logs from all machines, filter by host/source/text
  Proxmox      all guests from pve-exporter + the Proxmox hosts

Container metrics for this host's own containers come from Alloy, like on every other
Docker host — set up this LXC/VM with `labber setup` and answer yes to Docker.

Uptime Kuma (http://<monitoring-host>:3001), once after deployment:
  1. Create the admin account.
  2. Settings → Notifications → add Telegram (same bot and chat as .env), tick "Default enabled".
  3. Add a monitor per service: HTTP(s) with its URL (e.g. http://192.168.server.jellyfin:8096),
     interval 60s; TCP Port for services without a web page.
  Monitors and history live in the uptime-kuma-data volume (in the LXC's PBS backups).
