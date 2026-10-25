#!/usr/bin/env bash
# Validate and unit-test the Prometheus alert rules with promtool (needs only Docker).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rules="$(cd "$here/../../services/monitoring/config/prometheus" && pwd)"
# Prometheus as the template pins it (prom/prometheus:${PROMETHEUS_VERSION:-x.y.z} → prom/prometheus:x.y.z)
image=$(sed -nE 's/^ *image: *(prom\/prometheus):(\$\{[A-Z_]+:-([^}]+)\}|([^ ]+)).*/\1:\3\4/p' "$here/../../services/monitoring/docker-compose.yml")
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" check rules /rules/alert.rules.yml
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" test rules /tests/alert-rules.test.yml
# alertmanager.yml is a template (${TELEGRAM_*} filled in at container start, as the compose
# entrypoint does): check it filled in, with and without the quiet chat's own bot
am=$(mktemp -d); trap 'rm -rf "$am"' EXIT
chmod 755 "$am"            # amtool runs as "nobody" in its container
fill() {  # fill <manager token> <manager chat> → $am/alertmanager.yml, like the entrypoint
    local mt="${1:-123:loud}" mc="${2:--1001}"
    sed "s|\${TELEGRAM_MANAGER_BOT_TOKEN}|$mt|g; s|\${TELEGRAM_MANAGER_CHAT_ID}|$mc|g; s|\${TELEGRAM_BOT_TOKEN}|123:loud|g; s|\${TELEGRAM_CHAT_ID}|-1001|g" \
        "$here/../../services/monitoring/config/alertmanager/alertmanager.yml" > "$am/alertmanager.yml"
    chmod 644 "$am/alertmanager.yml"
}
for variant in "456:quiet -1002" ""; do
    # shellcheck disable=SC2086  # the two words are the two arguments
    fill $variant
    docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 check-config /a/alertmanager.yml >/dev/null \
        || { echo "FAIL: alertmanager.yml invalid (manager settings: '${variant:-none}')"; exit 1; }
    if grep -q 'TELEGRAM_[A-Z_]*}' "$am/alertmanager.yml"; then echo "FAIL: a placeholder was left unfilled"; exit 1; fi
done
fill "456:quiet" "-1002"
grep -q "bot_token: '456:quiet'" "$am/alertmanager.yml" || { echo "FAIL: the quiet chat's bot isn't used"; exit 1; }
fill "" ""
[[ $(grep -c "bot_token: '123:loud'" "$am/alertmanager.yml") -eq 2 ]] || { echo "FAIL: without its own bot the quiet chat doesn't fall back to the loud one"; exit 1; }
# routing: critical → the loud chat; warning → the quiet chat at once; info → the quiet chat at the 15:00 digest
route() { docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 \
    config routes test --config.file=/a/alertmanager.yml "severity=$1" alertname=X instance=h 2>&1; }
for case in critical:critical warning:manager info:manager; do
    sev=${case%%:*} want=${case#*:}
    got=$(route "$sev")
    [[ "$got" == "$want" ]] || { echo "FAIL: $sev alerts go to '$got', not '$want'"; exit 1; }
done
w=$(sed -n "/severity = warning/,/receiver/p" "$am/alertmanager.yml")
grep -q active_time_intervals <<<"$w" && { echo "FAIL: warnings wait for a time window"; exit 1; }
i=$(sed -n "/severity = info/,/receiver/p" "$am/alertmanager.yml")
grep -q "daily-digest" <<<"$i" || { echo "FAIL: notes aren't in the daily digest"; exit 1; }
if ! grep -E "start_time: '15:00'" "$am/alertmanager.yml" >/dev/null || ! grep -E "location: 'UTC'" "$am/alertmanager.yml" >/dev/null; then
    echo "FAIL: the daily digest isn't 15:00 UTC"; exit 1
fi
echo "ok   alertmanager: critical → loud chat at once; warning → quiet chat at once; info → quiet chat at the 15:00 UTC digest; quiet falls back to loud"
# ALERT_TARGET=ntfy: the entrypoint keeps alertmanager.yml's routes and swaps in receivers-ntfy.yml
cfg="$here/../../services/monitoring/config/alertmanager"
sed '/^receivers:/,$d' "$cfg/alertmanager.yml" | cat - "$cfg/receivers-ntfy.yml" \
    | sed "s|\${NTFY_URL}|http://ntfy.test:8080|g; s|\${NTFY_TOPIC}|alerts|g; s|\${NTFY_TOKEN}|tk_test|g" > "$am/alertmanager.yml"
docker run --rm -v "$am:/a:ro" --entrypoint amtool prom/alertmanager:v0.27.0 check-config /a/alertmanager.yml >/dev/null \
    || { echo "FAIL: the ntfy variant of alertmanager.yml is invalid"; exit 1; }
if grep -vE '^[[:space:]]*#' "$am/alertmanager.yml" | grep -qE 'telegram_configs|TELEGRAM|NTFY_[A-Z_]*}'; then echo "FAIL: the ntfy variant still has a Telegram receiver or a placeholder"; exit 1; fi
for case in critical:critical warning:manager info:manager; do
    sev=${case%%:*} want=${case#*:}
    got=$(route "$sev")
    [[ "$got" == "$want" ]] || { echo "FAIL: ntfy variant: $sev alerts go to '$got', not '$want'"; exit 1; }
done
grep -q "alerts?template=alertmanager&priority=5" <(sed -n "/name: 'critical'/,/name: 'manager'/p" "$am/alertmanager.yml") \
    || { echo "FAIL: ntfy variant: critical isn't sent with the top priority"; exit 1; }
[[ $(grep -c "credentials: 'tk_test'" "$am/alertmanager.yml") -eq 2 ]] || { echo "FAIL: ntfy variant: a receiver lacks the token"; exit 1; }
echo "ok   alertmanager (ntfy): the same routes and digest; critical with the top priority; both receivers with the token"
