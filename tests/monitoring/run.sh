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
sed 's|${TELEGRAM_BOT_TOKEN}|123:test|; s|${TELEGRAM_CHAT_ID}|-1001|' \
    "$here/../../services/monitoring/config/alertmanager/alertmanager.yml" > "$am/alertmanager.yml"
docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 check-config /a/alertmanager.yml
