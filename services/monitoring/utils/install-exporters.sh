#!/bin/bash
# Installs Grafana Alloy and smartctl_exporter as systemd services.
# Alloy replaces node_exporter + promtail: it pushes metrics to Prometheus
# via remote_write and ships journal logs to Loki.
#
# Usage:
#   ./install-exporters.sh <prometheus-url> <loki-url>
#
# Example:
#   ./install-exporters.sh http://192.168.management.monitoring:9090 http://192.168.management.monitoring:3100

set -e

SMARTCTL_EXPORTER_VERSION="0.12.0"
ARCH="amd64"

PROMETHEUS_URL="${1}"
LOKI_URL="${2}"

if [ -z "${PROMETHEUS_URL}" ] || [ -z "${LOKI_URL}" ]; then
  echo "Usage: $0 <prometheus-url> <loki-url>"
  exit 1
fi

echo "=== Installing smartctl_exporter v${SMARTCTL_EXPORTER_VERSION} ==="

curl -fsSL "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C /tmp/

install -m 755 /tmp/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH}/smartctl_exporter /usr/local/bin/smartctl_exporter
rm -rf /tmp/smartctl_exporter-*

cat > /etc/systemd/system/smartctl_exporter.service << 'EOF'
[Unit]
Description=Prometheus smartctl Exporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/smartctl_exporter \
  --smartctl.interval=300s
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable smartctl_exporter --now
echo "smartctl_exporter running on :9633"

echo ""
echo "=== Installing Grafana Alloy ==="

apt install -y gpg

mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

apt update
apt install -y alloy

# journal log access requires these groups
usermod -aG adm alloy
usermod -aG systemd-journal alloy

echo ""
echo "=== Writing Alloy config ==="

mkdir -p /etc/alloy

cat > /etc/alloy/config.alloy << EOF
logging {
  level = "info"
}

// ── Metrics ──────────────────────────────────────────────────────────────────

prometheus.exporter.unix "local" {
  enable_collectors = ["systemd", "processes", "hwmon", "thermal_zone"]
}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.local.targets
  forward_to      = [prometheus.relabel.node.receiver]
  scrape_interval = "15s"
}

prometheus.relabel "node" {
  forward_to = [prometheus.remote_write.central.receiver]
  rule {
    target_label = "job"
    replacement  = "proxmox-node-exporters"
  }
  rule {
    target_label = "host"
    replacement  = constants.hostname
  }
  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

prometheus.scrape "smartctl" {
  targets         = [{"__address__" = "localhost:9633"}]
  forward_to      = [prometheus.relabel.smartctl.receiver]
  scrape_interval = "300s"
}

prometheus.relabel "smartctl" {
  forward_to = [prometheus.remote_write.central.receiver]
  rule {
    target_label = "job"
    replacement  = "proxmox-smartctl-exporters"
  }
  rule {
    target_label = "host"
    replacement  = constants.hostname
  }
  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "${PROMETHEUS_URL}/api/v1/write"
  }
}

// ── Logs ─────────────────────────────────────────────────────────────────────

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "local" {
  forward_to    = [loki.write.central.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels = {
    host = constants.hostname,
    job  = "journal",
  }
  max_age = "24h"
}

loki.write "central" {
  endpoint {
    url = "${LOKI_URL}/loki/api/v1/push"
  }
}
EOF

systemctl restart alloy
systemctl enable alloy
echo "Alloy running — pushing metrics to ${PROMETHEUS_URL} and logs to ${LOKI_URL}"

echo ""
echo "=== Done ==="
echo "Verify:"
echo "  systemctl status alloy"
echo "  systemctl status smartctl_exporter"
echo "  curl http://localhost:12345/-/healthy"
