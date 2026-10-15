#!/usr/bin/env bash
# Validate and unit-test the Prometheus alert rules with promtool (needs only Docker).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rules="$(cd "$here/../../services/monitoring/config/prometheus" && pwd)"
image=prom/prometheus:v3.1.0    # keep in step with services/monitoring/docker-compose.yml
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" check rules /rules/alert.rules.yml
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" test rules /tests/alert-rules.test.yml
# alertmanager.yml is a template (${TELEGRAM_*} filled in at container start): check it filled in
am=$(mktemp -d); trap 'rm -rf "$am"' EXIT
chmod 755 "$am"            # amtool runs as "nobody" in its container
sed 's|${TELEGRAM_BOT_TOKEN}|123:test|; s|${TELEGRAM_CHAT_ID}|-1001|' \
    "$here/../../services/monitoring/config/alertmanager/alertmanager.yml" > "$am/alertmanager.yml"
chmod 644 "$am/alertmanager.yml"
docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 check-config /a/alertmanager.yml
# routing: critical goes out at once (every 6 h); warnings and notes only in the 15:00 UTC digest
route() { docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 \
    config routes test --config.file=/a/alertmanager.yml --tree "severity=$1" alertname=X instance=h 2>&1; }
for case in 'critical|severity="critical"' 'warning|severity="warning"' 'info|severity="info"'; do
    sev=${case%%|*} want=${case#*|}
    out=$(route "$sev")
    grep -F "{$want}" <<<"$out" >/dev/null || { echo "$out"; echo "FAIL: $sev alerts don't use the {$want} route"; exit 1; }
done
grep -E "start_time: '15:00'" "$am/alertmanager.yml" >/dev/null && grep -E "location: 'UTC'" "$am/alertmanager.yml" >/dev/null \
    || { echo "FAIL: the daily digest isn't 15:00 UTC"; exit 1; }
echo "ok   alertmanager routes: critical at once, warnings/notes in the 15:00 UTC digest"
