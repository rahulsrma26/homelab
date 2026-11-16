#!/usr/bin/env bash
# Install the weekly Renovate run on the Forgejo guest, as root, by hand from a tagged version (its
# token stays on this guest: never in CI, where a PR could read it). Usage: renovate/install.sh
# Then: /etc/renovate/renovate.conf (forgejo=, owner=, optional git_author="Renovate <renovate@…>"), the token in /etc/renovate/token, and:
# systemctl enable --now renovate.timer      (a run by hand: systemctl start renovate.service)
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
for c in docker git python3 curl; do command -v "$c" >/dev/null || { echo "needs $c" >&2; exit 1; }; done
install -d -o root -g root -m 755 /opt/renovate
install -o root -g root -m 755 "$src"/run.sh "$src"/weekly.sh /opt/renovate/
install -d -o root -g root -m 700 /etc/renovate
cat > /etc/systemd/system/renovate.service <<'UNIT'
[Unit]
Description=Renovate: propose image updates as PRs (weekly)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/renovate/weekly.sh
Nice=10
TimeoutStartSec=2h
UNIT
cat > /etc/systemd/system/renovate.timer <<'UNIT'
[Unit]
Description=Renovate every Monday (inside renovate.json's schedule, 00-06 UTC)
[Timer]
OnCalendar=Mon *-*-* 02:00:00 UTC
Persistent=true
RandomizedDelaySec=15min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
echo "installed; settings: /etc/renovate/renovate.conf; token: (umask 077; cat > /etc/renovate/token)"
