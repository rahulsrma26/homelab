# Setting up the monitoring stack

Deploying [`services/monitoring`](../services/monitoring/) (Prometheus, Loki, Grafana, Alertmanager, InfluxDB, pve-exporter) and connecting the hosts and guests to it. What it watches and how alerts are delivered: [architecture/monitoring.md](../architecture/monitoring.md).

## 1. A read-only Proxmox user (every host)

For pve-exporter, in each host's web UI:

1. **Datacenter → Permissions → Roles → Create:** `MonitoringRole` with `Sys.Audit` and `VM.Audit` (or use the built-in **PVEAuditor**).
2. **Users → Add:** `monitoring@pve` (Proxmox VE authentication), no expiry.
3. **Permissions → Add → User Permission:** path `/`, the user, the role, propagate on.

Its own user means stale credentials only ever ban the exporter's own address in fail2ban.

## 2. The LXC

4 cores, 4 GB RAM, ~100 GB disk, on the low-power host that runs longest on battery, with **a NIC in the management and the server VLAN** so guests on either push to it without firewall exceptions ([new-guest.md](new-guest.md)):

```bash
pct create <ID> local:vztmpl/debian-13-standard_<ver>_amd64.tar.zst --hostname monitoring \
  --cores 4 --memory 4096 --swap 512 --rootfs enc-nvme:100,mountoptions=noatime\;discard \
  --net0 name=eth0,bridge=vmbr0,tag=<mgmt-vid>,firewall=1,ip=<mgmt-ip>/24,gw=<mgmt-gw> \
  --net1 name=eth1,bridge=vmbr0,tag=<server-vid>,firewall=1,ip=<server-ip>/24 \
  --unprivileged 1 --features nesting=1 --onboot 1
```

Inside: `labber setup` (Docker: yes), then `labber monitoring install`. It asks for the values in `.env`: the Grafana and InfluxDB passwords and token (generated), `PVE_USER`/`PVE_PASSWORD` (the user from step 1), the Telegram bot token and chat id. Add each host to the `pve-exporter` targets in `config/prometheus/prometheus.yml`.

## 3. Hosts

On each Proxmox host, Alloy (metrics + the journal, pushed) and smartctl_exporter:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/services/monitoring/utils/install-exporters.sh) \
  http://192.168.management.monitoring:9090 \
  http://192.168.management.monitoring:3100
```

It rejects malformed URLs (e.g. `http:///…`). Node metrics include EDAC (ECC), ZFS, hwmon and systemd, which the alert rules use.

## 4. Guests

`labber setup` installs and configures Alloy in every guest (its "alloy" step, asking for the Prometheus and Loki URLs, or `--prometheus <url>`). Docker hosts also send container metrics and logs.

## 5. Home Assistant

The InfluxDB v2 integration: URL `http://192.168.server.monitoring:8086`, organisation `homelab`, bucket `homeassistant`, the token from `.env`.

## 6. Check

```bash
# in the monitoring LXC
docker compose ps
curl -s 'http://localhost:9090/api/v1/query?query=up' | head -c 300     # targets
curl -s http://localhost:3100/ready                                     # Loki
# on a host
systemctl status alloy smartctl_exporter
curl -s http://localhost:12345/-/healthy
```

Grafana comes with its dashboards provisioned (Proxmox, guests, containers, disks, logs).

## 7. A test alert

From the monitoring LXC; a Telegram message should arrive within ~30 seconds.
Alertmanager has no published host port. Run a temporary curl container in its
network namespace to reach the API without publishing it:

```bash
docker run --rm --network container:alertmanager curlimages/curl:8.12.1 \
  -fsS -X POST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","instance":"test","severity":"critical"},"annotations":{"summary":"test alert"}}]'
# resolve it at once:
docker run --rm --network container:alertmanager curlimages/curl:8.12.1 \
  -fsS -X POST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","instance":"test","severity":"critical"},"annotations":{"summary":"test alert"},"endsAt":"2000-01-01T00:00:00Z"}]'
```

Only `critical` arrives at once; `warning` and `info` wait for the daily digest.
