Central observability stack — metrics, logs, dashboards, and alerts.

Services:
  grafana       :3000  Dashboards and visualisation
  prometheus    :9090  Metrics storage (90d retention, 20GB cap)
  loki          :3100  Log aggregation (30d retention)
  influxdb      :8086  Time-series storage for Home Assistant (365d retention)
  alertmanager  :9093  Alert routing to Telegram
  pve-exporter  :9221  Proxmox API metrics for Prometheus
  cadvisor      :8080  Container metrics (internal only)

Before deployment:
  .env
  config/prometheus/prometheus.yml

After deployment:
  Run utils/install-exporters.sh on each Proxmox host to install Alloy + smartctl_exporter.
