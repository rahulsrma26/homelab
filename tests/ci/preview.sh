#!/usr/bin/env bash
# A preview of a Homepage config before it's merged (homelab-private: plans/automation-design.md →
# walkthrough 6): Homepage at the template's pinned image, the given config folder, no secrets
# (widgets needing an API key show nothing). On the test VM, port 8099.
#   tests/ci/preview.sh homepage <config folder> [port]      start or refresh it
#   tests/ci/preview.sh stop                                 remove it
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
name=labber-preview
if [[ "${1:-}" == stop ]]; then docker rm -f "$name" >/dev/null 2>&1 || true; echo "preview stopped"; exit 0; fi
[[ "${1:-}" == homepage && -d "${2:-}" ]] || { sed -n '2,7p' "$0"; exit 1; }
cfg=$(cd "$2" && pwd); port="${3:-8099}"
image=$(sed -nE 's/^[[:space:]]+image: ([^:]+):\$\{[A-Z_]+:-([^}]+)\}.*/\1:\2/p' "$here/services/homepage/docker-compose.yml" | head -1)
[[ -n "$image" ]] || { echo "error: no pinned image in services/homepage/docker-compose.yml" >&2; exit 1; }
work=$(mktemp -d); cp -r "$cfg/." "$work/"; chmod -R a+rX "$work"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --restart unless-stopped -p "$port:3000" -v "$work:/app/config" \
    -e HOMEPAGE_ALLOWED_HOSTS='*' "$image" >/dev/null
for _ in $(seq 30); do curl -fsS -o /dev/null "http://localhost:$port/" && break; sleep 2; done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/")
echo "preview: http://$(hostname -I | awk '{print $1}'):$port/  (HTTP $code, image ${image%@*}, config from $cfg)"
