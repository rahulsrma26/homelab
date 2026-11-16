#!/usr/bin/env bats
# On a machine labber has set up (run-setup.sh's LXC, after it became a Docker host): what a
# later `labber setup` may and may not change. Runs inside the test container, as root.

PATHS="/etc /usr/local /opt /root /var/lib/labber"
# files that change on their own (timers, shells, the package database)
VOLATILE='^/(etc/(mtab|resolv\.conf|hostname|hosts|ld\.so\.cache)|root/\.(bash_history|zsh_history|cache|lesshst|viminfo|zcompdump.*|local/share)|var/lib/labber/metrics/)'

others_but() {   # every setup step but the given ones, comma-separated (as push-tokens.sh does)
    local keep="$1"
    sed -n "s/^SETUP_STEPS=(\(.*\)).*/\1/p" "$(readlink -f "$(command -v labber)")" | head -n 1 \
        | tr " " "\n" | grep -vxE "$keep" | paste -sd, -
}
changed_since() {   # files under $PATHS changed after the marker, minus the volatile ones
    find $PATHS -xdev -newer "$1" \( -type f -o -type l \) 2>/dev/null | grep -vE "$VOLATILE" | sort
}
dry() { labber setup --dry-run "$@" </dev/null 2>&1 | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

setup_file() {
    # Alloy to a monitoring that isn't on this machine (nothing answers there; Alloy retries),
    # so the push token matters; and a container running, to see that nothing restarts it
    labber setup --yes --without "$(others_but alloy)" \
        --prometheus http://127.0.0.2:9090 --loki http://127.0.0.2:3100 </dev/null >/dev/null 2>&1
    docker run -d --name keepalive --restart unless-stopped busybox:1.37 sleep infinity >/dev/null 2>&1 \
        || docker start keepalive >/dev/null
}

@test "every step's status is done… or todo…, nothing else" {
    local lines bad
    lines=$(dry | grep -E '^ +[0-9]+ \[[ x]\] ')
    [ "$(wc -l <<< "$lines")" -ge 15 ]
    bad=$(grep -vE ' (done|todo)(: .*)?$' <<< "$lines" || true)
    [ -z "$bad" ] || { echo "$bad"; false; }
}

@test "--dry-run on a set-up machine changes no file" {
    local m; m=$(mktemp); sleep 1
    dry --yes >/dev/null
    run changed_since "$m"; rm -f "$m"
    [ -z "$output" ] || { echo "changed: $output"; false; }
}

@test "the push token step: ticked here (Alloy sends elsewhere, no token yet)" {
    rm -f /etc/alloy/push-token
    dry | grep -E '^ +[0-9]+ \[x\] push token for monitoring .* todo: none yet'
}

@test "only the steps asked for: Alloy with a token changes Alloy's files and labber's state, nothing else" {
    local m apt0 started0 tok
    tok=$(mktemp); echo 0123456789abcdef0123456789abcdef > "$tok"
    apt0=$(wc -l < /var/log/apt/history.log 2>/dev/null || echo 0)
    started0=$(docker inspect -f '{{.State.StartedAt}}' keepalive)
    m=$(mktemp); sleep 1
    # what push-tokens.sh runs in each guest; setup's own summary must name Alloy alone (a step that
    # ran without visible effect here, like a system update with nothing to upgrade, still shows)
    run labber setup --yes --without "$(others_but alloy)" --push-token-file "$tok" </dev/null
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<< "$output" | grep -E '^✓ done: ' | tail -n 1)" = "✓ done: alloy" ] || { echo "$output" | tail -5; false; }
    run changed_since "$m"; rm -f "$m" "$tok"
    local unexpected; unexpected=$(grep -vE '^/(etc/alloy/|var/lib/labber/setup\.state|etc/systemd/system/alloy\.service\.d/)' <<< "$output" | grep . || true)
    [ -z "$unexpected" ] || { echo "changed outside Alloy: $unexpected"; false; }
    [ "$(wc -l < /var/log/apt/history.log 2>/dev/null || echo 0)" = "$apt0" ]          # no apt run
    [ "$(docker inspect -f '{{.State.StartedAt}}' keepalive)" = "$started0" ]         # not restarted
    [ "$(grep -c bearer_token_file /etc/alloy/config.alloy)" -eq 2 ]
}

@test "the push token step after labber forgot Alloy's URLs: finds them in Alloy's config" {
    local tok; tok=$(mktemp); echo fedcba9876543210fedcba9876543210 > "$tok"
    sed -i '/^alloy_prometheus=/d; /^alloy_loki=/d' /var/lib/labber/setup.state
    rm -f /etc/alloy/push-token
    run labber setup --yes --without "$(others_but pushtoken)" --push-token-file "$tok" </dev/null
    rm -f "$tok"
    [ "$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<< "$output" | grep -E '^✓ done: ' | tail -n 1)" = "✓ done: pushtoken" ] || { echo "$output" | tail -5; false; }
    [ "$(cat /etc/alloy/push-token)" = fedcba9876543210fedcba9876543210 ]
    [ "$(grep -c bearer_token_file /etc/alloy/config.alloy)" -eq 2 ]
    grep -q 'url = "http://127.0.0.2:9090/api/v1/write"' /etc/alloy/config.alloy           # same monitoring
    grep -qx 'alloy_prometheus=http://127.0.0.2:9090' /var/lib/labber/setup.state          # remembered again
    dry | grep -E '^ +[0-9]+ \[ \] push token for monitoring .* done$'
}

@test "a guest with its own monitoring (localhost): needs a token like any other (it pushes through the push-gate)" {
    local tok; tok=$(mktemp); echo 0123456789abcdef0123456789abcdef > "$tok"
    rm -f /etc/alloy/push-token
    labber setup --yes --without "$(others_but alloy)" \
        --prometheus http://localhost:9090 --loki http://localhost:3100 </dev/null >/dev/null
    dry | grep -E '^ +[0-9]+ \[x\] push token for monitoring .* todo: none yet'
    run labber setup --yes --without "$(others_but pushtoken)" --push-token-file "$tok" </dev/null
    rm -f "$tok"
    [ "$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<< "$output" | grep -E '^✓ done: ' | tail -n 1)" = "✓ done: pushtoken" ] || { echo "$output" | tail -5; false; }
    grep -q 'url = "http://localhost:9090/api/v1/write"' /etc/alloy/config.alloy          # same monitoring
    [ "$(grep -c bearer_token_file /etc/alloy/config.alloy)" -eq 2 ]
    dry | grep -E '^ +[0-9]+ \[ \] push token for monitoring .* done$'
}

@test "setup with stdin closed and --yes never waits for an answer" {
    run timeout 300 labber setup --yes --without update </dev/null
    [ "$status" -ne 124 ]
}
