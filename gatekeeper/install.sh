#!/usr/bin/env bash
# Install the gatekeeper on the Forgejo LXC, as root, by hand (it is a trust anchor: never
# updated by the pipeline it guards). Usage: gatekeeper/install.sh   (from a checkout of a tagged version)
# Then: /etc/gatekeeper/gatekeeper.conf (from gatekeeper.conf.example), the token in /etc/gatekeeper/token, the
# release key in /etc/gatekeeper/release-key, and: systemctl enable --now gatekeeper.timer
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
id gatekeeper >/dev/null 2>&1 || useradd --system --home-dir /var/lib/gatekeeper --shell /usr/sbin/nologin gatekeeper
install -d -o root -g root -m 755 /opt/gatekeeper
install -o root -g root -m 644 "$src"/rules.py "$src"/registry.py /opt/gatekeeper/
install -o root -g root -m 755 "$src"/gatekeeper.py /opt/gatekeeper/
install -d -o root -g gatekeeper -m 750 /etc/gatekeeper
install -d -o gatekeeper -g gatekeeper -m 700 /var/lib/gatekeeper
install -d -m 755 /var/lib/labber/metrics
touch /var/lib/labber/metrics/gatekeeper.prom && chown gatekeeper:gatekeeper /var/lib/labber/metrics/gatekeeper.prom
cat > /etc/systemd/system/gatekeeper.service <<'UNIT'
[Unit]
Description=gatekeeper: approve low-risk PRs, promote dev → canary → main, sign release records
After=network-online.target docker.service
[Service]
Type=oneshot
User=gatekeeper
Group=gatekeeper
ExecStart=/usr/bin/python3 /opt/gatekeeper/gatekeeper.py
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/gatekeeper /var/lib/labber/metrics/gatekeeper.prom
PrivateTmp=yes
UNIT
cat > /etc/systemd/system/gatekeeper.timer <<'UNIT'
[Unit]
Description=gatekeeper every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
echo "installed; key and token: install -o root -g gatekeeper -m 640 <file> /etc/gatekeeper/{release-key,token}"
