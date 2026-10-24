#!/bin/bash
# Installs Grafana Alloy and smartctl_exporter as systemd services.
# Alloy replaces node_exporter + promtail: it pushes metrics to Prometheus
# via remote_write and ships journal logs to Loki.
# --igpu also installs Intel iGPU metrics (intel_gpu_top every 15 s, through Alloy).
#
# Usage:
#   ./install-exporters.sh <prometheus-url> <loki-url> [--igpu]
#
# Example:
#   ./install-exporters.sh http://192.168.management.monitoring:9090 http://192.168.management.monitoring:3100 --igpu

set -e

SMARTCTL_EXPORTER_VERSION="0.12.0"
ARCH="amd64"

PROMETHEUS_URL="${1}"
LOKI_URL="${2}"
IGPU=0
case "${3:-}" in
  "") ;;
  --igpu) IGPU=1 ;;
  *) echo "Unknown option: ${3} (only --igpu)"; exit 1 ;;
esac
# metrics written by local scripts (iGPU), read by Alloy's textfile collector
TEXTFILE_DIR=/var/lib/node-textfile

if [ -z "${PROMETHEUS_URL}" ] || [ -z "${LOKI_URL}" ]; then
  echo "Usage: $0 <prometheus-url> <loki-url> [--igpu]"
  exit 1
fi

# catch typos like "http:///host" or a missing scheme before they end up in the config
for url in "${PROMETHEUS_URL}" "${LOKI_URL}"; do
  if [[ ! "${url}" =~ ^https?://[^/]+ ]]; then
    echo "Not a valid URL: ${url} (expected e.g. http://192.168.management.monitoring:9090)"
    exit 1
  fi
done
PROMETHEUS_URL="${PROMETHEUS_URL%/}"
LOKI_URL="${LOKI_URL%/}"

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
echo "=== Intel iGPU metrics ==="

mkdir -p "${TEXTFILE_DIR}"
chmod 755 "${TEXTFILE_DIR}"
if [ "${IGPU}" = 1 ]; then
  if ! grep -qs 0x8086 /sys/class/drm/card*/device/vendor; then
    echo "No Intel GPU found (/sys/class/drm) — skipping the iGPU metrics"
  else
    apt install -y intel-gpu-tools python3

    cat > /usr/local/sbin/igpu-metrics << 'EOF'
#!/usr/bin/python3
# installed by install-exporters.sh --igpu: Intel iGPU metrics from intel_gpu_top
# every 15 s, as Prometheus text for Alloy's textfile collector.
import glob, json, os, re, subprocess, sys, tempfile, time

DIR = "/var/lib/node-textfile"
OUT = os.path.join(DIR, "igpu.prom")
SECONDS = 15


def rc6_file():
    # the kernel's RC6 counter; intel_gpu_top's own rc6 reads 0 on some kernels
    for card in sorted(glob.glob("/sys/class/drm/card[0-9]*")):
        try:
            if open(f"{card}/device/vendor").read().strip() != "0x8086":
                continue
        except OSError:
            continue
        for f in (f"{card}/gt/gt0/rc6_residency_ms", f"{card}/power/rc6_residency_ms"):
            if os.path.exists(f):
                return f
    return None


class Rc6:
    def __init__(self):
        self.file, self.last = rc6_file(), None

    def percent(self):
        """RC6 share of the time since the previous call, or None."""
        if not self.file:
            return None
        try:
            now = (time.monotonic() * 1000, int(open(self.file).read()))
        except (OSError, ValueError):
            return None
        last, self.last = self.last, now
        if not last or now[0] <= last[0]:
            return None
        return min(100.0, max(0.0, (now[1] - last[1]) * 100 / (now[0] - last[0])))


def write(lines):
    fd, tmp = tempfile.mkstemp(dir=DIR, prefix=".igpu.prom.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


def metrics(s, rc6=None):
    out = ["igpu_metrics_up 1"]
    for engine, v in sorted(s.get("engines", {}).items()):
        if isinstance(v, dict) and "busy" in v:
            # "Render/3D/0" in older versions, "Render/3D" in newer ones
            name = re.sub(r"/0$", "", engine).replace('"', "")
            out.append(f'igpu_engine_busy_percent{{engine="{name}"}} {float(v["busy"]):.2f}')
    freq = s.get("frequency", {})
    for k in ("actual", "requested"):
        if k in freq:
            out.append(f"igpu_frequency_{k}_hertz {float(freq[k]) * 1e6:.0f}")
    if rc6 is not None:
        out.append(f"igpu_rc6_percent {rc6:.2f}")
    elif "value" in s.get("rc6", {}):
        out.append(f'igpu_rc6_percent {float(s["rc6"]["value"]):.2f}')
    power = s.get("power", {})
    if "GPU" in power:
        out.append(f'igpu_power_watts {float(power["GPU"]):.2f}')
    if "Package" in power:
        out.append(f'igpu_package_power_watts {float(power["Package"]):.2f}')
    return out


def main():
    os.makedirs(DIR, exist_ok=True)
    # line-buffered: a pipe would otherwise hold samples back until its buffer fills
    p = subprocess.Popen(["stdbuf", "-oL", "intel_gpu_top", "-J", "-s", str(SECONDS * 1000)],
                         stdout=subprocess.PIPE, text=True)
    dec, buf, rc6 = json.JSONDecoder(), "", Rc6()
    rc6.percent()
    for chunk in iter(lambda: p.stdout.read(1), ""):
        buf += chunk
        if chunk != "}":
            continue
        # the stream is "[ {sample}, {sample}, ..."; decode each sample once it's complete
        start = buf.find("{")
        if start < 0:
            continue
        try:
            sample, end = dec.raw_decode(buf, start)
        except json.JSONDecodeError:
            continue
        buf = buf[end:]
        write(metrics(sample, rc6.percent()))
    write(["igpu_metrics_up 0"])
    sys.exit(p.wait() or 1)


if __name__ == "__main__":
    main()
EOF
    chmod 755 /usr/local/sbin/igpu-metrics

    cat > /etc/systemd/system/igpu-metrics.service << 'EOF'
[Unit]
Description=Intel iGPU metrics for Alloy (intel_gpu_top, every 15 s)

[Service]
ExecStart=/usr/local/sbin/igpu-metrics
Restart=always
RestartSec=30
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable igpu-metrics
    systemctl restart igpu-metrics
    echo "iGPU metrics written every 15 s to ${TEXTFILE_DIR}/igpu.prom"
  fi
fi

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
  textfile {
    directory = "${TEXTFILE_DIR}"
  }
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

// Alloy's own counters, for the log alerts: what it sent, what it dropped and why
prometheus.exporter.self "alloy" { }

prometheus.scrape "alloy" {
  targets         = prometheus.exporter.self.alloy.targets
  forward_to      = [prometheus.relabel.alloy.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "alloy" {
  forward_to = [prometheus.remote_write.central.receiver]
  rule {
    source_labels = ["__name__"]
    regex         = "loki_(process_dropped_lines_total|write_(sent|dropped)_(bytes|entries)_total)"
    action        = "keep"
  }
  rule {
    target_label = "job"
    replacement  = "alloy"
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

// per unit: at most 50 lines/s (bursts of 500); the rest is dropped and counted, so one noisy
// service can't flood Loki for every host
loki.process "journal" {
  forward_to = [loki.write.central.receiver]
  stage.limit {
    rate          = 50
    burst         = 500
    by_label_name = "unit"
    drop          = true
  }
}

loki.source.journal "local" {
  forward_to    = [loki.process.journal.receiver]
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
if [ "${IGPU}" = 1 ]; then
  echo "  systemctl status igpu-metrics; cat ${TEXTFILE_DIR}/igpu.prom"
fi
