#!/usr/bin/env bash
# PVE_HOSTS in .env becomes Prometheus's pve-exporter target list (services/monitoring): starts
# Prometheus through the real docker-compose.yml with a test .env, then reads its targets.
#   - two hosts → two pve-exporter targets, labelled with the host, asking pve-exporter for it
#   - empty     → Prometheus still starts, with no pve-exporter targets
# Needs only Docker.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose="$(cd "$here/../../services/monitoring" && pwd)/docker-compose.yml"
project="pvetargets-$$" env=$(mktemp)
cleanup() { docker compose -p "$project" -f "$compose" --env-file "$env" down -v >/dev/null 2>&1 || true; rm -f "$env"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; docker logs --tail 20 prometheus >&2 2>&1 || true; exit 1; }
pass() { echo "ok   $*"; }

targets() {   # targets <PVE_HOSTS> → the pve-exporter targets as "instance <target in the scrape URL>" lines
    printf 'PVE_HOSTS=%s\nLOKI_DATA=loki-data\n' "$1" > "$env"
    docker compose -p "$project" -f "$compose" --env-file "$env" up -d --force-recreate prometheus >/dev/null 2>&1 \
        || fail "prometheus didn't start (PVE_HOSTS='$1')"
    for _ in $(seq 30); do
        docker exec prometheus wget -qO- http://localhost:9090/-/ready >/dev/null 2>&1 && break; sleep 2
    done
    # the target list is read shortly after start: wait until the other jobs' targets are there
    local json=""
    for _ in $(seq 30); do
        json=$(docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null || true)
        if [[ -n "$1" ]]; then grep -q '"job":"pve-exporter"' <<<"$json" && break
        else grep -q '"job":"loki"' <<<"$json" && break; fi
        sleep 2
    done
    python3 -c '
import json, sys
for t in json.loads(sys.argv[1])["data"]["activeTargets"]:
    if t["labels"].get("job") == "pve-exporter":
        q = dict(p.split("=", 1) for p in t["scrapeUrl"].split("?", 1)[1].split("&"))
        print(t["labels"]["instance"], q.get("target", "?"))' "$json"
}

out=$(targets "pve-a,pve-b") || exit 1
[[ "$(sort <<<"$out")" == $'pve-a pve-a\npve-b pve-b' ]] || { echo "$out"; fail "expected targets pve-a and pve-b"; }
pass "PVE_HOSTS=pve-a,pve-b → two pve-exporter targets, labelled and asked for by host"

out=$(targets "") || exit 1
[[ -z "$out" ]] || { echo "$out"; fail "empty PVE_HOSTS should give no pve-exporter targets"; }
pass "empty PVE_HOSTS → Prometheus starts, no pve-exporter targets"
