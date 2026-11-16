#!/usr/bin/env bash
# Point this machine's apt and Docker at a pkg-cache. Safe when the cache is down: apt goes
# direct (a 1-second check per run), Docker falls back to Docker Hub by itself.
#   client-setup.sh <cache host> [apt port] [mirror port]     set up (or update)
#   client-setup.sh --remove                                   undo
set -euo pipefail
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
APT_CONF=/etc/apt/apt.conf.d/01pkg-cache DETECT=/usr/local/bin/pkg-cache-detect DAEMON=/etc/docker/daemon.json

docker_conf() {   # docker_conf add <host:port> | docker_conf remove : edit daemon.json, keep the rest
    command -v docker >/dev/null || return 0
    command -v python3 >/dev/null || { echo "  (no python3: add \"registry-mirrors\": [\"http://$2\"] and \"insecure-registries\": [\"$2\"] to $DAEMON yourself)"; return 0; }
    mkdir -p /etc/docker
    python3 - "$1" "${2:-}" "$DAEMON" <<'PY'
import json, os, sys
act, hp, path = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
for k in ('registry-mirrors', 'insecure-registries'):
    d[k] = [x for x in d.get(k, []) if 'pkg-cache' not in x and x.rstrip('/').split('//')[-1] != hp]
if act == 'add':
    d['registry-mirrors'] = [f'http://{hp}'] + d['registry-mirrors']
    d['insecure-registries'] = [hp] + d['insecure-registries']   # plain HTTP inside the LAN; images are checked by digest
for k in ('registry-mirrors', 'insecure-registries'):
    if not d[k]: del d[k]
json.dump(d, open(path + '.new', 'w'), indent=2); os.replace(path + '.new', path)
PY
    systemctl reload docker 2>/dev/null || systemctl restart docker
}

if [[ "${1:-}" == --remove ]]; then
    rm -f "$APT_CONF" "$DETECT"
    old=$(python3 -c "import json;print(' '.join(json.load(open('$DAEMON')).get('insecure-registries',[])))" 2>/dev/null || true)
    for hp in $old; do docker_conf remove "$hp"; done
    echo "pkg-cache: removed"; exit 0
fi
host="${1:?usage: client-setup.sh <cache host> [apt port] [mirror port] | --remove}"; ap="${2:-3142}"; mp="${3:-5000}"

cat > "$DETECT" <<SH
#!/bin/sh
# apt asks this for a proxy on each run: the cache if it answers within a second, else direct
if timeout 1 bash -c 'exec 3<>/dev/tcp/$host/$ap' 2>/dev/null; then echo "http://$host:$ap"; else echo DIRECT; fi
SH
chmod 755 "$DETECT"
printf 'Acquire::http::Proxy-Auto-Detect "%s";\n' "$DETECT" > "$APT_CONF"
docker_conf add "$host:$mp"
echo "pkg-cache: apt → $($DETECT) · docker mirror → http://$host:$mp"
