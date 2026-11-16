#!/usr/bin/env bash
# One Renovate run: it follows only the templates in the auto and prepared groups (homelab-config's
# policy/groups.yml, readable on the LAN); the rest (by hand, not deployed) it leaves alone.
# Run from a checkout of homelab (it lists services/ there). Needs RENOVATE_TOKEN;
# RENOVATE_GITHUB_COM_TOKEN (read-only, for release notes) is optional.
# Usage: renovate/run.sh <forgejo url> <owner> [renovate options, e.g. --dry-run]
# Weekly: renovate/install.sh (a timer on the Forgejo guest; the token never reaches CI).
set -euo pipefail
url="${1:?forgejo url}" owner="${2:?owner}"; shift 2
image=renovate/renovate:44.183.0
cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT; chmod 644 "$cfg"     # Renovate's container runs as a non-root user
groups=$(curl -fsS "$url/$owner/homelab-config/raw/branch/main/policy/groups.yml")
followed=$(sed -nE 's/^(auto|prepared):[[:space:]]*\[(.*)\].*/\2/p' <<< "$groups" | tr ',' '\n' | tr -d ' "'"'" | grep -v '^$' | sort -u)
[[ -n "$followed" ]] || { echo "error: no auto/prepared services in policy/groups.yml" >&2; exit 1; }
others=()
for d in services/*/; do s=$(basename "$d"); grep -qxF "$s" <<< "$followed" || others+=("$s"); done
python3 - "$cfg" "${others[@]}" <<'PY'
import json, sys
out, skip = sys.argv[1], sys.argv[2:]
json.dump({'packageRules': [{'description': 'by hand or not deployed: Renovate leaves it alone',
                             'matchFileNames': [f'services/{s}/**' for s in skip], 'enabled': False}]} if skip else {}, open(out, 'w'))
PY
echo ":: Renovate follows: $(tr '\n' ' ' <<< "$followed")"
docker run --rm --network host --memory "${RENOVATE_MEMORY:-1536m}" -e RENOVATE_TOKEN -e RENOVATE_GITHUB_COM_TOKEN -e LOG_LEVEL="${LOG_LEVEL:-info}" -e LOG_FORMAT \
    -v "$cfg:/usr/src/app/config.json:ro" -e RENOVATE_CONFIG_FILE=/usr/src/app/config.json \
    "$image" --platform=forgejo --endpoint="$url/api/v1" --onboarding=false --require-config=optional \
    "$@" "$owner/homelab"
