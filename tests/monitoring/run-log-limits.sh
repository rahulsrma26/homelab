#!/usr/bin/env bash
# End-to-end test of the log caps: the Alloy config `labber setup` writes for a Docker host,
# shipping to a Loki with services/monitoring's loki-config.yml. Three containers log at once:
#   - flood: as fast as it can     → capped (100 lines/s per container, bursts of 1000)
#   - quiet: one line a second     → arrives complete, despite the flood next to it
#   - noise: a known noise line    → dropped, counted as reason="noise"
# Alloy's own counters (dropped lines, sent bytes) must show it. Needs only Docker.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# the image as the template pins it (grafana/loki:${LOKI_VERSION:-x.y.z} → grafana/loki:x.y.z)
loki_image=$(sed -nE 's/^ *image: *(grafana\/loki):(\$\{[A-Z_]+:-([^}]+)\}|([^ ]+)).*/\1:\3\4/p' "$repo/services/monitoring/docker-compose.yml")
alloy_image=grafana/alloy:v1.20.1     # as in tests/labber/run-unit.sh
net="loglimits-$$" out=$(mktemp -d)
cleanup() { docker rm -f "loki-$$" "alloy-$$" "flood-$$" "quiet-$$" "noise-$$" >/dev/null 2>&1 || true
            docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$out"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; docker logs --tail 20 "alloy-$$" >&2 2>&1 || true; exit 1; }
pass() { echo "ok   $*"; }

# the config labber writes for a Docker host, pointed at this test's Loki
docker build -q -t labber-unit -f "$repo/tests/labber/Dockerfile.unit" "$repo/tests/labber" >/dev/null
docker run --rm -v "$repo:/repo:ro" -v "$out:/out" labber-unit bash -c "bash /repo/tests/labber/gen-alloy-configs.sh /out >/dev/null; chown -R $(id -u):$(id -g) /out"
[[ -s "$out/docker.alloy" ]] || fail "no docker config generated"
sed -i -E 's#url = "http://[^"]*/loki/api/v1/push"#url = "http://loki-'$$':3100/loki/api/v1/push"#' "$out/docker.alloy"
# the journal isn't there in a container: drop that source, keep everything else as generated
python3 - "$out/docker.alloy" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'loki\.source\.journal "local" \{.*?\n\}\n', '', s, flags=re.S)
# find the test containers within seconds (the default looks once a minute)
s = s.replace('discovery.docker "local" {\n', 'discovery.docker "local" {\n  refresh_interval = "5s"\n', 1)
open(p, 'w').write(s)
EOF
chmod 644 "$out/docker.alloy"

docker network create "$net" >/dev/null
docker run -d --name "loki-$$" --network "$net" \
    -v "$repo/services/monitoring/config/loki/loki-config.yml:/etc/loki/loki-config.yml:ro" \
    "$loki_image" -config.file=/etc/loki/loki-config.yml >/dev/null
docker run -d --name "alloy-$$" --network "$net" --hostname "logtest" \
    -v "$out:/c:ro" -v /var/run/docker.sock:/var/run/docker.sock:ro \
    "$alloy_image" run --server.http.listen-addr=0.0.0.0:12345 /c/docker.alloy >/dev/null
q() { docker run --rm --network "$net" curlimages/curl:8.11.1 -fsS "$@"; }
for _ in $(seq 60); do q "http://loki-$$:3100/ready" >/dev/null 2>&1 && q "http://alloy-$$:12345/-/ready" >/dev/null 2>&1 && break; sleep 2; done
q "http://alloy-$$:12345/-/ready" >/dev/null || fail "alloy didn't start"

secs=20
docker run -d --name "flood-$$" alpine:3 sh -c "end=\$((\$(date +%s)+$secs)); i=0; while [ \$(date +%s) -lt \$end ]; do i=\$((i+1)); echo flood \$i; done; echo produced \$i; sleep 60" >/dev/null
docker run -d --name "quiet-$$" alpine:3 sh -c "for i in \$(seq $secs); do echo quiet \$i; sleep 1; done; sleep 60" >/dev/null
docker run -d --name "noise-$$" alpine:3 sh -c "for i in \$(seq $secs); do echo 'nginx: using uninitialized \"go2rtc_stream_proxy\" variable'; sleep 1; done; sleep 60" >/dev/null
# wait until the quiet container's lines are all in (or 2 minutes), then count
count() { q -G "http://loki-$$:3100/loki/api/v1/query" --data-urlencode "query=sum(count_over_time({container=\"$1\"}[10m]))" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else 0)'; }
sleep "$secs"
for _ in $(seq 24); do [[ "$(count "quiet-$$")" -ge "$secs" ]] && break; sleep 5; done
sleep 5

produced=$(docker logs "flood-$$" 2>&1 | sed -n 's/^produced //p')
flood=$(count "flood-$$") quiet=$(count "quiet-$$") noise=$(count "noise-$$")
echo "     flood: $produced written, $flood in Loki · quiet: $quiet of $secs · noise: $noise"

[[ -n "$produced" && "$produced" -gt 20000 ]] || fail "the flood container didn't produce enough lines ($produced)"
max=$(( 100 * (secs + 60) + 1000 ))   # its whole life at 100/s + one burst
[[ "$flood" -le "$max" ]] || fail "flood not capped: $flood lines arrived (allowed ≤ $max)"
[[ "$flood" -ge 1000 ]] || fail "flood capped too hard: only $flood lines arrived"
pass "a flooding container is capped ($flood of $produced lines; ≤ 100/s + a burst of 1000)"
[[ "$quiet" -eq "$secs" ]] || fail "the quiet container lost lines next to the flood ($quiet of $secs)"
pass "a quiet container next to it arrives complete ($quiet of $secs)"
[[ "$noise" -eq 0 ]] || fail "known noise wasn't dropped ($noise lines arrived)"
pass "known noise is dropped"

m=$(q "http://alloy-$$:12345/metrics")
grep -E '^loki_process_dropped_lines_total\{[^}]*reason="ratelimit_drop_stage"[^}]*\} [1-9]' <<<"$m" >/dev/null || fail "no ratelimit drops counted"
grep -E '^loki_process_dropped_lines_total\{[^}]*reason="noise"[^}]*\} [1-9]' <<<"$m" >/dev/null || fail "no noise drops counted"
grep -E '^loki_write_sent_bytes_total\{[^}]*\} [1-9]' <<<"$m" >/dev/null || fail "no sent bytes counted"
pass "Alloy counts its drops (ratelimit, noise) and sent bytes for the alerts"
