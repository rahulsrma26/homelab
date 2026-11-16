#!/bin/sh
# push-gate: in front of Prometheus (9090) and Loki (3100). Their push paths (remote write,
# Loki push, OTLP) need a token from PUSH_TOKENS when PUSH_AUTH=on; with log, pushes without
# one pass but show as group "-" in this container's log; off: everything passes. Queries,
# the UIs and every other path pass as before.
set -eu
mode="${PUSH_AUTH:-log}"
case "$mode" in off|log|on) ;; *) echo "PUSH_AUTH must be off, log or on (not '$mode')" >&2; exit 1 ;; esac
map=/etc/nginx/push-tokens.map
: > "$map"
n=0
for pair in $(echo "${PUSH_TOKENS:-}" | tr ',' ' '); do
    g="${pair%%=*}"; t="${pair#*=}"
    [ -n "$t" ] || continue                                   # a group without a token: none
    echo "$g" | grep -Eq '^[a-z0-9_-]+$' || { echo "PUSH_TOKENS: bad group name '$g'" >&2; exit 1; }
    echo "$t" | grep -Eq '^[A-Za-z0-9._~+/=-]{32,}$' || { echo "PUSH_TOKENS: the token of '$g' needs 32+ token characters" >&2; exit 1; }
    printf '"Bearer %s" "%s";\n' "$t" "$g" >> "$map"
    n=$((n + 1))
done
if [ "$mode" = on ] && [ "$n" -eq 0 ]; then echo "PUSH_AUTH=on without any token in PUSH_TOKENS: nothing could push" >&2; exit 1; fi
cat > /etc/nginx/conf.d/default.conf <<CONF
map_hash_bucket_size 128;                       # keys: "Bearer " + a 64-character token
map \$http_authorization \$push_group { default "-"; include $map; }
map "$mode:\$push_group" \$push_refused { "on:-" 1; default 0; }
log_format push '\$time_iso8601 push \$remote_addr group=\$push_group status=\$status \$uri bytes=\$request_length';
map "\$push_group:\$status" \$push_log { "~^-:" 1; "~:[45][0-9][0-9]\$" 1; default 0; }   # no token, or failed
resolver 127.0.0.11 valid=10s;

server {
    listen 9090;
    client_max_body_size 0;
    set \$up http://prometheus:9090;
    location ~ ^/api/v1/(write|otlp/) {
        access_log /dev/stdout push if=\$push_log;
        client_body_buffer_size 1m;                # a push (Alloy batches up to 1 MiB) stays in memory, not a temp file
        if (\$push_refused) { return 401 "a push token is required\n"; }
        proxy_set_header Authorization "";
        proxy_pass \$up;
    }
    location / { access_log off; proxy_pass \$up; }
}

server {
    listen 3100;
    client_max_body_size 0;
    set \$up http://loki:3100;
    location ~ ^/(loki/api/v1/push|api/prom/push|otlp/) {
        access_log /dev/stdout push if=\$push_log;
        client_body_buffer_size 1m;                # a push (Alloy batches up to 1 MiB) stays in memory, not a temp file
        if (\$push_refused) { return 401 "a push token is required\n"; }
        proxy_set_header Authorization "";
        proxy_pass \$up;
    }
    location / {
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;        # Loki's live tail (websocket)
        proxy_set_header Connection \$http_connection;
        proxy_pass \$up;
    }
}
CONF
echo "push-gate: PUSH_AUTH=$mode, $n token group(s)"
exec nginx -g 'daemon off;'
