Central observability stack — metrics, logs, dashboards, and alerts.

Services:
  grafana       :3000  Dashboards and visualisation
  prometheus    :9090  Metrics storage (90d retention, 20GB cap)
  loki          :3100  Log aggregation (30d retention)
  influxdb      :8086  Time-series storage for Home Assistant (365d retention)
  alertmanager  :9093  Alert routing to Telegram (Docker network only)
  pve-exporter  :9221  Proxmox API metrics for Prometheus (Docker network only)

Before deployment:
  .env
  config/prometheus/prometheus.yml

After deployment:
  Run utils/install-exporters.sh on each Proxmox host to install Alloy + smartctl_exporter.
  LXCs/VMs: `labber setup` installs Alloy with the same layout (job "guest-node-exporters",
  label kind=lxc|vm) plus a health check that exports labber_reboot_required,
  labber_restart_required_services and labber_security_updates_pending.

Alerts to Telegram (config/alertmanager/alertmanager.yml), two speeds:
  critical  HostDown, HostNotReporting, DiskSpaceCritical, DiskSpaceFull, DiskFillingFast,
            SmartHealthFailed, ZfsPoolNotOnline, MemoryUncorrectableError: at once, then
            every 6 h while it lasts
  warning   the rest: one daily digest at 15:00 UTC with whatever is still firing then
  info      ServiceUpdateAvailable: at the digest, then a weekly reminder
  Alerts appear in Grafana right away, whatever their delivery time. Alertmanager is
  private to the stack; a future authenticated proxy needs a private path to it.
  HostNotReporting stays active for up to one day after a host's last sample. After
  that the host is forgotten: automatic expiry does not establish recovery.

Alerts (config/prometheus/alert.rules.yml, tested by tests/monitoring/run.sh):
  HostDown             a target Prometheus scrapes is down
  HostNotReporting     a host/guest that pushes via Alloy stopped sending metrics
  SystemdUnitFailed    a systemd service is failed for 15 min
  RebootRequired       newer kernel installed for over a day
  ServicesNeedRestart  services on outdated libraries for over a day
  SecurityUpdatesStuck security updates pending for a week
  DiskSpaceLow         a filesystem over 80% for 30 min (warning: the daily digest)
  DiskSpaceCritical    over 90% (critical)
  DiskSpaceFull        over 95% (critical); only the highest of the three is sent
  DiskFillingFast      over half full and, at the last 6 h's rate, full within a day (critical)
  MemoryUncorrectableError  an uncorrectable ECC / IB-ECC error (EDAC) on a Proxmox host
  MemoryCorrectableErrors   more than 3 corrected ECC errors in 24h (a failing module)
  ZfsPoolNotOnline     a ZFS pool degraded/faulted for 5 min
  ContainerRestarting  a container restarted 3+ times in 15 min (Docker hosts)
  ContainerGone        a container that was running stopped or was removed
  ContainerOOMKilled   a container ran out of memory
  ServiceUpdateAvailable  labber check-updates found an update (info: weekly note)
  GPUTemperatureHigh   an NVIDIA GPU touches 95 °C, or stays at 90 °C+ for 15 min (labber setup's gpu step)

Dashboards (Grafana → Homelab folder, provisioned from config/grafana/provisioning/dashboards):
  Guests       every VM/LXC set up by labber: uptime, CPU, memory, disk, failed services, reboot, updates
  Containers   per-container CPU, memory, network, restarts, OOM kills; service updates
  Logs         journal + container logs from all machines, filter by host/source/text
  Proxmox      all guests from pve-exporter + the Proxmox hosts
  Disks        every disk on the hosts with smartctl_exporter (SATA and NVMe): health,
               warnings, bad blocks, error logs, temperatures (smartctl + each NVMe sensor),
               wear, data written, power-on time; raw SATA SMART attributes
  GPU          NVIDIA GPUs (labber setup's gpu step): load, VRAM (also per container),
               temperature, power, clocks, fan, thermal throttling; Intel iGPUs on the
               Proxmox hosts (install-exporters.sh --igpu): engine load (Video = decode/
               encode), frequency, power, idle time (its temperature is the CPU's)

Container metrics for this host's own containers come from Alloy, like on every other
Docker host — set up this LXC/VM with `labber setup` and answer yes to Docker.

Uptime Kuma is its own service (services/uptime-kuma), on a different machine, so it can
report when this host is down. It checks Grafana, Prometheus and Home Assistant from the outside.

Network boundary:
  Prometheus :9090 and Loki :3100 accept Alloy writes and expose their query APIs.
  Firewall rules allow trusted management/server agents and the public VM's
  specific DMZ exception. Home VLAN access to these APIs is blocked before the
  broader home -> server port allowance; NIC membership alone is insufficient.
  Prometheus HTTP shutdown/reload is disabled; reload through a container restart
  or SIGHUP. pve-exporter accepts request-selected targets and holds Proxmox
  credentials, so its port must stay unpublished. Alertmanager's API can silence
  alerts and also stays unpublished.
