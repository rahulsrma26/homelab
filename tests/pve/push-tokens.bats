#!/usr/bin/env bats
# services/monitoring/utils/push-tokens.sh on a real Proxmox host (pve-ci; tests/pve/run.sh), the
# way it's run: hidden prompts on a terminal, the host and every LXC. A stub monitoring on the host
# records each push's token group. Guests: one like a real one (labber from this tree, Docker with a
# running container, Alloy, its remembered URLs gone, the system update pending), monitoring's own
# guest (Alloy to localhost: it pushes through the push-gate too, so it takes the token), one whose
# labber is too old (refused, nothing left behind).

NET="${PVE_CI_NET:?set by tests/pve/run.sh: the test bridge /24 prefix, e.g. 192.0.2}"
MON=$NET.1
TH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TG=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
REAL=1102; OWN=1103; OLD=1104

ct() {   # ct ID IP: a Debian CT on the test bridge, started
    pct create "$1" local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst --hostname "pt$1" --storage cipool \
        --rootfs cipool:6 --memory 1536 --cores 2 --unprivileged 1 --features nesting=1,keyctl=1 \
        --net0 "name=eth0,bridge=vmbr1,ip=$2/24,gw=$MON" >/dev/null
    pct start "$1"; sleep 4
}
in_ct() { local id="$1"; shift; pct exec "$id" -- bash -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=C.UTF-8; $*"; }
others_but() { sed -n "s/^SETUP_STEPS=(\(.*\)).*/\1/p" /root/repo/labber/labber | head -n 1 | tr " " "\n" | grep -vxE "$1" | paste -sd, -; }
pushes() { grep " $1 " /root/stub/pushes.log | tail -n 20 | awk '{print $NF}' | sort -u | paste -sd' ' -; }

labber_ct() {   # labber from this tree in a CT (a git repo of it inside, as its source)
    pct push "$1" /root/repo.tar /root/repo.tar
    in_ct "$1" 'apt-get update -qq >/dev/null && apt-get install -y -qq git curl ca-certificates >/dev/null
        mkdir -p /opt/src && tar -xf /root/repo.tar -C /opt/src && cd /opt/src && git init -q && git add -A \
        && git -c user.name=t -c user.email=t@t commit -qm tree && git branch -M main
        bash /opt/src/labber/labber install >/dev/null 2>&1; labber source set file:///opt/src main >/dev/null 2>&1
        labber update </dev/null >/dev/null 2>&1; true'
}

setup_file() {
    # the host's firewall as on a fresh pve-ci (a kept run of labber-host.bats leaves it on)
    rm -f /etc/pve/firewall/cluster.fw; pve-firewall restart >/dev/null 2>&1 || true
    # the stub monitoring, on the host's address on the test bridge
    mkdir -p /root/stub
    cat > /root/stub/stub.py <<EOF
import http.server, threading, time
G = {"Bearer $TH": "hosts", "Bearer $TG": "guests"}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open("/root/stub/pushes.log", "a") as f:
            f.write(f"{time.strftime('%T')} {self.client_address[0]} {self.server.server_port} group={G.get(self.headers.get('Authorization', ''), '-')}\n")
        self.send_response(204); self.end_headers()
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
for p in (9090, 3100):
    s = http.server.ThreadingHTTPServer(("$MON", p), H); threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
EOF
    systemd-run --unit=pt-stub python3 /root/stub/stub.py >/dev/null
    # the host's Alloy, as install-exporters.sh sets it up, to the stub (no token yet)
    bash /root/repo/services/monitoring/utils/install-exporters.sh "http://$MON:9090" "http://$MON:3100" > /root/install-exporters.log 2>&1

    # a real guest: labber from this tree (a git repo of it inside), Docker, Alloy to the stub
    ct "$REAL" $NET.102
    tar -C /root/repo -cf /root/repo.tar . && labber_ct "$REAL"
    in_ct "$REAL" "labber setup --yes --virt lxc --docker yes --without '$(others_but 'docker|dockerlogs|alloy')' \
        --prometheus http://$MON:9090 --loki http://$MON:3100 </dev/null" > /root/real-setup.log 2>&1
    in_ct "$REAL" 'docker run -d --name keepalive --restart unless-stopped busybox:1.37 sleep infinity >/dev/null
        sed -i "/^alloy_prometheus=/d; /^alloy_loki=/d" /var/lib/labber/setup.state'   # set up before labber remembered them

    # monitoring's own guest: Alloy sends to localhost (nothing answers here; Alloy retries)
    ct "$OWN" $NET.103
    labber_ct "$OWN"
    in_ct "$OWN" "labber setup --yes --virt lxc --docker no --without '$(others_but alloy)' \
        --prometheus http://localhost:9090 --loki http://localhost:3100 </dev/null" > /root/own-setup.log 2>&1

    # a guest on an old labber: its update brings nothing new, its help has no --push-token-file
    ct "$OLD" $NET.104
    in_ct "$OLD" "printf '#!/bin/sh\nVERSION=\"4.4.4\"\ncase \"\$1\" in help) echo \"labber v4.4.4\";; esac\nexit 0\n' > /usr/local/bin/labber && chmod +x /usr/local/bin/labber
        mkdir -p /etc/alloy && printf 'url = \"http://$MON:9090/api/v1/write\"\nurl = \"http://$MON:3100/loki/api/v1/push\"\n' > /etc/alloy/config.alloy"

    # before: what must not change on the real guest
    in_ct "$REAL" 'wc -l < /var/log/apt/history.log' > /root/real-apt0
    in_ct "$REAL" 'docker inspect -f "{{.State.StartedAt}}" keepalive' > /root/real-started0
    sleep 20
}
teardown_file() {
    [[ "${KEEP:-0}" == 1 ]] && return 0
    local id; for id in $REAL $OWN $OLD; do pct stop "$id" >/dev/null 2>&1; pct destroy "$id" --purge >/dev/null 2>&1; done
    systemctl stop pt-stub >/dev/null 2>&1 || true
}

@test "before: the host and the real guest push without a token" {
    [[ "$(pushes "$MON")" == *group=-* ]]
    [[ "$(pushes $NET.102)" == *group=-* ]]
}

@test "the run: host ✓, the real guest ✓, monitoring's own guest ✓, the old one ✗; exit 1" {
    # the tokens typed at the two hidden prompts, on a terminal (script)
    run python3 /root/repo/tests/pve/answer.py 'PUSH_TOKEN_HOSTS.*: $' "$TH" 'PUSH_TOKEN_GUESTS.*: $' "$TG" -- \
        bash /root/repo/services/monitoring/utils/push-tokens.sh --from file:///root/repo
    echo "$output" > /root/push-tokens.out
    [ "$status" -ne 0 ]
    [[ "$output" == *"✓ host"* ]]
    [[ "$output" == *"✓ $REAL"* ]]
    [[ "$output" == *"✓ $OWN"* ]]
    [[ "$output" == *"✗ $OLD"* ]]; [[ "$output" == *"has no --push-token-file"* ]]
    [[ "$output" != *"$TH"* && "$output" != *"$TG"* ]]                   # never echoed
}

@test "after: the host and the real guest push with their group's token" {
    sleep 25
    [[ "$(grep " $MON " /root/stub/pushes.log | tail -n 3 | awk '{print $NF}' | sort -u)" == group=hosts ]]
    [[ "$(grep " $NET.102 " /root/stub/pushes.log | tail -n 3 | awk '{print $NF}' | sort -u)" == group=guests ]]
}

@test "the real guest: only Alloy changed (no apt run, its container not restarted), token in place, URLs remembered again" {
    [ "$(in_ct "$REAL" 'wc -l < /var/log/apt/history.log')" = "$(cat /root/real-apt0)" ]
    [ "$(in_ct "$REAL" 'docker inspect -f "{{.State.StartedAt}}" keepalive')" = "$(cat /root/real-started0)" ]
    [ "$(in_ct "$REAL" 'grep -c bearer_token_file /etc/alloy/config.alloy')" = 2 ]
    [ "$(in_ct "$REAL" 'stat -c "%U:%G %a" /etc/alloy/push-token')" = "root:alloy 640" ]
    in_ct "$REAL" 'grep -c cadvisor /etc/alloy/config.alloy' | grep -qv '^0$'        # the Docker parts kept
    in_ct "$REAL" "grep -qx 'alloy_prometheus=http://$MON:9090' /var/lib/labber/setup.state"
    in_ct "$REAL" '! test -e /root/.push-token'
}

@test "monitoring's own guest: the token in its Alloy config, still to localhost, Alloy running" {
    [ "$(in_ct "$OWN" 'grep -c bearer_token_file /etc/alloy/config.alloy')" = 2 ]
    [ "$(in_ct "$OWN" 'cat /etc/alloy/push-token')" = "$TG" ]
    in_ct "$OWN" 'grep -q "url = \"http://localhost:9090/api/v1/write\"" /etc/alloy/config.alloy'
    in_ct "$OWN" 'systemctl is-active -q alloy'
}

@test "the host: its old Alloy config kept; the token file root and Alloy only" {
    [ -s /root/config.alloy.before-push-token ]
    [ "$(grep -c bearer_token_file /root/config.alloy.before-push-token)" = 0 ]
    [ "$(grep -c bearer_token_file /etc/alloy/config.alloy)" = 2 ]
    [ "$(stat -c '%U %a' /etc/alloy/push-token)" = "root 640" ] || [ "$(stat -c '%U %a' /etc/alloy/push-token)" = "root 600" ]
}

@test "the refused guest: nothing left behind" {
    in_ct "$OLD" '! test -e /root/.push-token'
    in_ct "$OLD" '! test -e /etc/alloy/push-token'
    [ -s "/root/push-tokens-$OLD.log" ]                                   # its log kept for you
}

@test "a second run with Enter at both prompts changes nothing" {
    sum0=$(md5sum /etc/alloy/config.alloy)
    run python3 /root/repo/tests/pve/answer.py 'PUSH_TOKEN_HOSTS.*: $' '' 'PUSH_TOKEN_GUESTS.*: $' '' -- \
        bash /root/repo/services/monitoring/utils/push-tokens.sh --from file:///root/repo
    [ "$status" -eq 0 ]
    [ "$(md5sum /etc/alloy/config.alloy)" = "$sum0" ]
    [[ "$output" != *"::"* ]]                                              # nothing done
}
