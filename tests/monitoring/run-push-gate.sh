#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016   # "cond && ok || bad": ok is an echo; the sed matches a literal ${...}
# push-gate (services/monitoring/config/push-gate/start.sh) in its real image, in front of stub
# upstreams named prometheus and loki: tokens per mode, what it logs, and no request body
# buffered to disk for a push of normal size. Needs Docker (the test VM).
set -euo pipefail
cd "$(dirname "$0")/../.."
img=$(sed -n 's/.*image: nginx:\${PUSH_GATE_VERSION:-\(.*\)}.*/nginx:\1/p' services/monitoring/docker-compose.yml)
net=pg-test-$$; tok=0123456789abcdef0123456789abcdef0123456789abcdef
fail=0; ok() { echo "ok $*"; }; bad() { echo "FAIL $*"; fail=1; }
cleanup() { docker rm -f pg-gate pg-prometheus pg-loki pg-client >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT; cleanup

docker network create "$net" >/dev/null
stub='import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self): self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.send_response(204); self.end_headers()
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", int(__import__("sys").argv[1])), H).serve_forever()'
docker run -d --name pg-prometheus --network "$net" --network-alias prometheus python:3.13-alpine python3 -c "$stub" 9090 >/dev/null
docker run -d --name pg-loki --network "$net" --network-alias loki python:3.13-alpine python3 -c "$stub" 3100 >/dev/null
docker run -d --name pg-client --network "$net" alpine:3.22 sleep 600 >/dev/null
docker exec pg-client apk add -q curl >/dev/null
head -c 400000 /dev/urandom > /tmp/pg-body.$$; docker cp /tmp/pg-body.$$ pg-client:/body; rm -f /tmp/pg-body.$$

gate() {   # gate MODE: (re)start push-gate in that mode
    docker rm -f pg-gate >/dev/null 2>&1 || true
    docker run -d --name pg-gate --network "$net" -e PUSH_AUTH="$1" -e PUSH_TOKENS="guests=$tok" \
        -v "$PWD/services/monitoring/config/push-gate:/push-gate:ro" --entrypoint /bin/sh "$img" /push-gate/start.sh >/dev/null
    for _ in $(seq 30); do docker exec pg-client curl -fs -o /dev/null http://pg-gate:9090/-/ready && return 0; sleep 0.5; done
    docker logs pg-gate; return 1
}
post() {   # post PORT PATH [TOKEN]: the status code
    docker exec pg-client curl -s -o /dev/null -w '%{http_code}' --data-binary @/body ${3:+-H "Authorization: Bearer $3"} "http://pg-gate:$1$2"
}

gate log
[ "$(post 9090 /api/v1/write "$tok")" = 204 ] && ok "log: a push with the token passes" || bad "log: token push"
[ "$(post 3100 /loki/api/v1/push)" = 204 ] && ok "log: a push without one passes" || bad "log: tokenless push"
sleep 1; logs=$(docker logs pg-gate 2>&1)
[[ "$logs" == *"group=- status=204 /loki/api/v1/push"* ]] && ok "log: the tokenless push logged as group -" || bad "log: tokenless push not logged"
[[ "$logs" != *"group=guests"* ]] && ok "log: the push with a token not logged" || bad "log: token push logged"
[[ "$logs" != *"buffered to a temporary file"* ]] && ok "a 400 kB push is not buffered to disk" || bad "a 400 kB push was buffered to disk"

gate on
[ "$(post 9090 /api/v1/write)" = 401 ] && ok "on: no token, 401" || bad "on: no token"
[ "$(post 3100 /loki/api/v1/push "${tok}x")" = 401 ] && ok "on: a wrong token, 401" || bad "on: wrong token"
[ "$(post 3100 /loki/api/v1/push "$tok")" = 204 ] && ok "on: the token passes" || bad "on: token push"
[ "$(docker exec pg-client curl -s -o /dev/null -w '%{http_code}' http://pg-gate:9090/api/v1/query?query=up)" = 200 ] \
    && ok "on: a query needs no token" || bad "on: query"

exit "$fail"
