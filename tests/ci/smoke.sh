#!/usr/bin/env bash
# CI on a disposable Docker host: install a service from the base branch with test values,
# seed it (if the template has tests/seed), upgrade it to the PR's version, check it again,
# and make sure none of its generated secrets shows up in its logs.
# Usage: tests/ci/smoke.sh <svc> <base checkout> <head checkout>
set -euo pipefail
svc="$1" base="$2" head="$3"
# a template CI can't run (e.g. it needs an NVIDIA GPU) says why in tests/ci-skip: skipped, and said so
if [[ -f "$head/services/$svc/tests/ci-skip" ]]; then
    echo "::warning::$svc is not tested in CI: $(head -1 "$head/services/$svc/tests/ci-skip")"
    echo "$svc: SKIPPED (tests/ci-skip): $(head -1 "$head/services/$svc/tests/ci-skip")"
    exit 0
fi
work=$(mktemp -d); export LABBER_SERVICE_BASE="$work/services" LABBER_SYNC_LOCKED=1 LABBER_AUTOGEN=1
# never fails the test: files the containers wrote belong to their users (root), hence sudo
cleanup() {
    [[ -d "$LABBER_SERVICE_BASE/$svc" ]] && (cd "$LABBER_SERVICE_BASE/$svc" && docker compose down -v --remove-orphans >/dev/null 2>&1)
    sudo -n rm -rf "$work" 2>/dev/null || rm -rf "$work" 2>/dev/null || true
}
mkdir -p "$LABBER_SERVICE_BASE"
# a leftover of this service from an interrupted earlier run (a disposable CI host): gone first
docker ps -aq --filter "label=com.docker.compose.project=$svc" | xargs -r docker rm -f >/dev/null 2>&1 || true
for net in $(docker network ls -q --filter "label=com.docker.compose.project=$svc"); do
    # a stale endpoint (its container already gone) blocks the network's removal: disconnect it first
    for ep in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null); do
        docker network disconnect -f "$net" "$ep" >/dev/null 2>&1 || true
    done
    docker network rm "$net" >/dev/null 2>&1 || true
done
lab() { bash "$head/labber/labber" "$@" </dev/null; }
# on a failure, the service's last log lines (CI must explain itself)
explain() {
    [[ -d "$LABBER_SERVICE_BASE/$svc" ]] || return 0
    local c
    for c in $(cd "$LABBER_SERVICE_BASE/$svc" && docker compose config --services 2>/dev/null); do
        (cd "$LABBER_SERVICE_BASE/$svc" && docker compose logs --no-color --tail 6 "$c" 2>&1 | sed 's/^/    | /')
    done
}
trap 'rc=$?; (( rc == 0 )) || explain; cleanup' EXIT

fill_test_values() {   # whatever labber can't fill without a terminal: test values, recorded as secrets
    local env="$1/.env" k
    # a choice gets its first option; anything else still unanswered a random test value
    local line k v r re_choice='\{\{[^}]*choice\(([^,)]*)[^}]*\}\}' re_any='\{\{[^}]*\}\}'
    while IFS= read -r line; do
        k=${line%%=*}; v=${line#*=}
        while [[ "$v" =~ $re_choice ]]; do v=${v/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}"}; done
        while [[ "$v" =~ $re_any ]]; do
            r="ci$(openssl rand -hex 12)"; v=${v/"${BASH_REMATCH[0]}"/"$r"}
        done
        v=${v//\'/}; sed -i "s|^$k=.*|$k='$v'|" "$env"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=.*\{\{' "$env")
    # the template's meaningful test values (no GPU, local storage, valid URLs, …) win
    local t="$head/services/$svc/tests/ci-values"      # (not *.env: the repo ignores those, a guard against real ones)
    if [[ -f "$t" ]]; then
        # the version under test's CI files, also into a base install (which may predate them)
        mkdir -p "$1/tests" && cp -r "$head/services/$svc/tests/." "$1/tests/"
        while IFS= read -r line; do
            [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
            if grep -q "^${BASH_REMATCH[1]}=" "$env"; then sed -i "s|^${BASH_REMATCH[1]}=.*|${BASH_REMATCH[1]}=${BASH_REMATCH[2]}|" "$env"
            else echo "$line" >> "$env"; fi
        done < "$t"
    fi
    # the secrets to look for in the logs: values of keys named like one (not URLs, hostnames, …)
    grep -E '^[A-Za-z_]*(PASSWORD|SECRET|TOKEN|KEY|SALT)[A-Za-z0-9_]*=' "$env" | cut -d= -f2- | tr -d "'\"" | grep -E '^.{8,}$' >> "$work/secrets" || true
}

if [[ -d "$base/services/$svc" ]]; then
    echo ":: $svc: install the version on the base branch"
    lab --source "$base" "$svc" install >/dev/null 2>&1 || true
    fill_test_values "$LABBER_SERVICE_BASE/$svc"
    lab "$svc" start
    lab "$svc" healthy
    if [[ -x "$LABBER_SERVICE_BASE/$svc/tests/seed" ]]; then (cd "$LABBER_SERVICE_BASE/$svc" && tests/seed && tests/check); fi
    echo ":: $svc: upgrade to the PR's version"
    lab --source "$head" "$svc" update --rollback-on-failure
else
    echo ":: $svc: new template, install the PR's version"
    lab --source "$head" "$svc" install >/dev/null 2>&1 || true
    fill_test_values "$LABBER_SERVICE_BASE/$svc"
    lab "$svc" start
    if [[ -x "$LABBER_SERVICE_BASE/$svc/tests/seed" ]]; then (cd "$LABBER_SERVICE_BASE/$svc" && tests/seed); fi
fi
lab "$svc" healthy
if [[ -x "$LABBER_SERVICE_BASE/$svc/tests/check" ]]; then (cd "$LABBER_SERVICE_BASE/$svc" && tests/check); fi
echo ":: $svc: no generated secret in its logs"
logs=$(cd "$LABBER_SERVICE_BASE/$svc" && docker compose logs --no-color 2>&1)
while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if grep -qF -- "$s" <<< "$logs"; then echo "error: a secret from .env appears in $svc's logs" >&2; exit 1; fi
done < <(sort -u "$work/secrets" 2>/dev/null)
echo "✓ $svc"
