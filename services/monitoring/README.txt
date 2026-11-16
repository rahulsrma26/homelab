Central observability stack — metrics, logs, dashboards, and alerts.

Services:
  grafana       :3000  Dashboards and visualisation
  prometheus    :9090  Metrics storage (90d retention, 20GB cap)
  loki          :3100  Log aggregation (30d retention)
  influxdb      :8086  Time-series storage for Home Assistant (365d retention)
  alertmanager  :9093  Alert routing to Telegram or ntfy (Docker network only)
  pve-exporter  :9221  Proxmox API metrics for Prometheus (Docker network only)

Check the stack (on its host, in this folder): ./tester
  containers, Prometheus (rules, scrape targets, the PVE_HOSTS hosts, who stopped reporting, what's
  firing), Loki, Alertmanager (one or two Telegram chats, failed sends), Grafana, InfluxDB; a
  summary and an exit code. --test-alerts also sends one test alert to each chat and checks
  Telegram accepted it; --size lists what takes up the most series.

Proxmox hosts to scrape: PVE_HOSTS in .env, comma-separated (their management addresses or
names). Prometheus turns it into a target list when it starts, so prometheus.yml is the same
everywhere and `labber monitoring update` never touches your hosts. A change in .env needs
docker compose up -d prometheus (a recreate). TRAEFIK_METRICS works the same way: Traefik's
metrics port (host:8082), for the certificate-expiry alerts (warning under 20 days, critical
under 5: Let's Encrypt renews 30 days ahead).

InfluxDB's data: INFLUXDB_DATA in .env, a folder (a bind mount: e.g. on a dataset that is
snapshotted and replicated), or empty for the named volume influxdb-data. Moving existing data
(the history stays; tested with a real write before and a read after):
  docker compose stop influxdb
  sudo mkdir -p <folder>
  sudo cp -a "$(docker volume inspect -f '{{.Mountpoint}}' monitoring_influxdb-data)/." <folder>/
  set INFLUXDB_DATA=<folder> in .env, then: docker compose up -d influxdb
  check Home Assistant's history in Grafana, then: docker volume rm monitoring_influxdb-data
(the volume's name: docker volume ls | grep influxdb-data)

Who may push (push-gate): Prometheus and Loki publish no port of their own; push-gate (nginx)
answers on 9090 and 3100. Their push paths (remote write, Loki push, OTLP) need a token from a
group in .env (PUSH_TOKEN_HOSTS, _GUESTS, _CI, _DMZ) when PUSH_AUTH=on; queries, the UIs and
Grafana pass as before. Each sender keeps its group's token in /etc/alloy/push-token (root and
Alloy only) and sends it as a bearer token. Rolling it out without losing a sample:
  1. PUSH_AUTH=log (the default) and a token per group: openssl rand -hex 32, into .env;
     docker compose up -d push-gate
  2. each sender gets its group's token (a file, then deleted):
       guests:  labber setup --push-token-file <file>   (untick all but Alloy; --yes would also run
                every other ticked step, the system update among them)
       hosts:   install-exporters.sh <prometheus> <loki> [--igpu] --push-token-file <file>
     or, on each Proxmox host, both at once: utils/push-tokens.sh asks for the hosts' and the
     guests' token (hidden) and does the host and every LXC sending here; VMs by hand
  3. docker logs push-gate: it logs only pushes without a token (group=-) and failed ones;
     who still pushes without one (their address)
  4. none left for a day: PUSH_AUTH=on, docker compose up -d push-gate
A leaked token: a new one for that group, step 2 for its senders. A token proves the group,
not the labels a sender writes.

Before deployment:
  .env
  config/prometheus/prometheus.yml

After deployment:
  Run utils/install-exporters.sh on each Proxmox host to install Alloy + smartctl_exporter,
  and an hourly backup-age-metrics timer: each dataset's newest sanoid snapshot and each
  guest's newest backup on a PBS storage (for SnapshotsStale / BackupStale).
  LXCs/VMs: `labber setup` installs Alloy with the same layout (job "guest-node-exporters",
  label kind=lxc|vm) plus a health check that exports labber_reboot_required,
  labber_restart_required_services and labber_security_updates_pending.

Alerts to Telegram (config/alertmanager/alertmanager.yml), two chats, three levels:
  critical  the loud chat (TELEGRAM_BOT_TOKEN/CHAT_ID), at once, then every 6 h while it lasts:
            HostDown, HostNotReporting, DiskSpaceCritical, DiskSpaceFull, DiskFillingFast,
            SmartHealthFailed, ZfsPoolNotOnline, MemoryUncorrectableError, GPUTemperatureHigh
  warning   the quiet chat (TELEGRAM_MANAGER_BOT_TOKEN/CHAT_ID, notifications off), at once, then
            daily while it lasts: strong signals to act on within a day (a failed service, a
            restart loop, an OOM kill, drive wear, ECC errors, a write surge, logs flooding,
            stuck security updates, high memory)
  info      the quiet chat, in one digest at 15:00 UTC, then weekly: routine (reboot due,
            services to restart, an update available, disk 80 %, high CPU, a stopped container)
  Without TELEGRAM_MANAGER_* set, everything goes to the loud chat.
  ALERT_TARGET=ntfy instead: the same levels and timing, to one ntfy topic (NTFY_URL,
  NTFY_TOPIC, NTFY_TOKEN: a send-only token, see services/ntfy); critical with the top
  priority. The routes stay in alertmanager.yml; receivers-ntfy.yml replaces its receivers.
  Alerts appear in Grafana right away, whatever their delivery time. Alertmanager is
  private to the stack; a future authenticated proxy needs a private path to it.
  HostNotReporting stays active for up to one day after a host's last sample. After
  that the host is forgotten: automatic expiry does not establish recovery.

Alerts (config/prometheus/alert.rules.yml, tested by tests/monitoring/run.sh):
  HostDown             a target Prometheus scrapes is down (not Traefik's metrics: see below)
  HostNotReporting     a host/guest that pushes via Alloy stopped sending metrics; when a Proxmox
                       host goes silent, only the host alerts, not each of its guests (matched by
                       name: a guest's Proxmox name must equal its hostname)
  SystemdUnitFailed    a systemd service is failed for 15 min
  RebootRequired       newer kernel or NVIDIA driver installed for over a day
  ServicesNeedRestart  services on outdated libraries for over a day
  SnapshotsStale       a dataset's newest sanoid snapshot is over 26 h old
  BackupStale          an existing guest's newest PBS backup is over 26 h old (deleted guests: never)
  CertificateExpiresSoon  Traefik's certificate under 20 days (VerySoon, critical: under 5)
  CertMetricsUnreachable  Traefik's metrics port can't be read for 15 min (warning: expiry unchecked)
  ReleaseFeedBehind    a guest stays on an older release record than the gatekeeper's for 2 h
  SecurityUpdatesStuck security updates pending for a week
  HighMemory           over 90% of its memory for 30 min (warning): hosts and VMs from their own
                       MemAvailable, LXCs from the host's view (pve-exporter); a spike is fine
  DiskSpaceLow         a filesystem over 80% for 30 min (info: the daily digest)
  DiskSpaceCritical    over 90% (critical)
  DiskWritesSurge      a physical disk on a Proxmox host wrote over 3× its usual day (the previous
                       7 days' average) and over 50 GB in 24 h (warning): a runaway process wearing
                       out an SSD; guests' virtual disks are left out. Followed by serial, so
                       disks swapping names (nvme0n1 ↔ nvme1n1) at a reboot don't count
  DiskSpaceFull        over 95% (critical); only the highest of the three is sent
  DiskFillingFast      over half full and, at the last 6 h's rate, full within a day (critical)
  (the disk alerts skip LXC filesystems: the host reports every dataset, each LXC's root
   disk included as subvol-<id>-disk-0, so a dataset mounted into LXCs alerts once)
  MemoryUncorrectableError  an uncorrectable ECC / IB-ECC error (EDAC) on a Proxmox host
  MemoryCorrectableErrors   more than 3 corrected ECC errors in 24h (a failing module)
  ZfsPoolNotOnline     a ZFS pool degraded/faulted for 5 min
  ContainerRestarting  a container restarted 3+ times in 15 min (Docker hosts)
  ContainerGone        a container that was running stopped or was removed
  ContainerOOMKilled   a container ran out of memory
  ServiceUpdateAvailable  labber check-updates found an update (info: weekly note)
  GPUTemperatureHigh   an NVIDIA GPU touches 95 °C, or stays at 90 °C+ for 15 min (labber setup's gpu step)
  LogsCapped           a host hit its log cap (Alloy: 100 lines/s per container, 50 per journal unit)
  LogsNotDelivered     log lines left a host but never reached Loki
  LogFlood             a host sends more than 100 kB/s of logs for 15 min
  LokiRejectingLogs    Loki turned lines away (its own per-stream limits)

Log caps, so one host can't flood Loki or fill its disk:
  1. at the source   Alloy (labber setup, install-exporters.sh) drops known noise and caps each
                     container and journal unit; drops are counted (loki_process_dropped_lines_total)
  2. in Loki         per stream 1 MB/s (burst 5 MB), 4 MB/s overall; over-long lines are cut
  3. the disk        LOKI_DATA in .env: a path (its own dataset with a quota, owned by uid 10001)
                     instead of the default named volume, so a flood can't fill Prometheus's disk
                     (the DiskSpace* alerts cover it like any mount)
  4. the alerts      above (warnings, in the quiet chat at once)

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
