#!/usr/bin/env bats
# Unit tests for labber's functions. No Docker daemon, network or VM needed.
# Run with: tests/labber/run-unit.sh   (or: make test-labber-unit)

setup() {
    LABBER="${LABBER:-$BATS_TEST_DIRNAME/../../services/labber}"
    # shellcheck disable=SC1090
    source "$LABBER"
    set +u    # labber runs with -u; bats' own internals don't
    T="$BATS_TEST_TMPDIR"
    LABBER_STATE_DIR="$T/state"
    UPDATES_FILE="$T/updates"
    cd "$T"
}

# ── placeholders ──────────────────────────────────────────────────────────────

@test "tpl_list finds every placeholder, anywhere in a value" {
    run tpl_list 'http://{{ host }}:{{ port | default(8000) }}/v1 and {{ s | generate([A-Za-z0-9],16) }}'
    [ "${lines[0]}" = "host		" ]
    [ "${lines[1]}" = "port	default	8000" ]
    [ "${lines[2]}" = "s	generate	[A-Za-z0-9],16" ]
    [ "${#lines[@]}" -eq 3 ]
    [ -z "$(tpl_list 'http://example:8080 {not} {{Bad Name}} plain')" ]
    run tpl_list '{{x|default(a:b/c)}}{{y | default() }}'      # no spaces needed; empty default
    [ "${lines[0]}" = "x	default	a:b/c" ]
    [ "${lines[1]}" = "y	default	" ]
}

@test "tpl_fill replaces one name everywhere, leaves the others" {
    v='http://{{ host }}:{{ port | default(80) }}/{{ host }}'
    [ "$(tpl_fill "$v" host 10.0.0.1)" = 'http://10.0.0.1:{{ port | default(80) }}/10.0.0.1' ]
    [ "$(tpl_fill "$(tpl_fill "$v" host h)" port 81)" = 'http://h:81/h' ]
    [ "$(tpl_fill 'a{{ x }}b' x 'v&\1$y')" = 'av&\1$yb' ]          # no sed-style surprises
}

@test "generators: known specs, formats, validation" {
    for g in hex64 base64_32 uuid '[A-Za-z0-9],16' '[a-z],3'; do gen_known "$g"; done
    for g in hex foo '[A-Z]' 'base64_' ''; do ! gen_known "$g"; done
    [[ "$(gen_value hex64)" =~ ^[a-f0-9]{64}$ ]]
    [[ "$(gen_value '[A-Za-z0-9],16')" =~ ^[A-Za-z0-9]{16}$ ]]
    [[ "$(gen_value '[a-c],40')" =~ ^[a-c]{40}$ ]]
    [ "$(gen_value base64_32 | wc -c)" -eq 44 ]
    gen_valid uuid "$(gen_value uuid)"
    [ "$(gen_value hex64)" != "$(gen_value hex64)" ]
    gen_valid hex4 beEF;  ! gen_valid hex4 beefa;  ! gen_valid hex4 zzzz
    gen_valid '[A-Za-z0-9],16' 'any chars ok, 16+'; ! gen_valid '[A-Za-z0-9],16' short
    ! gen_valid uuid not-a-uuid; ! gen_valid hex4 ''
    [ "$(gen_desc hex64)" = "64 hex characters" ]
    [ "$(gen_desc '[A-Za-z0-9],16')" = "at least 16 characters" ]
}

@test "fill: each name asked once, defaults, generated secrets, typed values" {
    command -v script >/dev/null || skip "needs script(1)"
    printf '%s\n' 'S={{ s | generate(hex64) }}' 'P={{ p | generate([A-Za-z0-9],16) }}   # note' \
        'TOKEN={{ token }}' 'URL=http://{{ host }}:{{ port | default(8000) }}/v1' 'URL2=http://{{ host }}/x' 'KEEP=1' > .env
    printf 'source "%s"; set +u\nfill_env_placeholders .env\n' "$LABBER" > fill.sh
    # answers: generate s and p? no · s (typed, too short → asked again) · s · p: Enter → generated ·
    # token · host (asked once) · port: Enter → 8000
    run script -qefc "bash fill.sh" /dev/null <<< $'n\nshort\nbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef\n\nmy-token\n10.0.0.9\n\n'
    echo "$output"
    [ "$(env_get .env S)" = beefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef ]
    [[ "$(env_get .env P)" =~ ^[A-Za-z0-9]{16}$ ]]
    grep -q '# note' .env
    [ "$(env_get .env TOKEN)" = my-token ]
    [ "$(env_get .env URL)" = "http://10.0.0.9:8000/v1" ]
    [ "$(env_get .env URL2)" = "http://10.0.0.9/x" ]
    [ "$(env_get .env KEEP)" = 1 ]
    [ "$(grep -c 'host (required)' <<< "$output")" -eq 1 ]
    [[ "$output" == *"needs 64 hex characters"* ]]
    [[ "$output" == *"Generate s p?"* ]]
    [ -z "$(env_placeholders .env)" ]
}

@test "fill: skipping a required value leaves it unset" {
    command -v script >/dev/null || skip "needs script(1)"
    printf 'TOKEN={{ token }}\nURL=http://{{ host | default(h) }}/{{ token }}\n' > .env
    printf 'source "%s"; set +u\nfill_env_placeholders .env\n' "$LABBER" > fill.sh
    run script -qefc "bash fill.sh" /dev/null <<< $'\n\n'
    [ "$(env_placeholders .env | tr '\n' ' ')" = "TOKEN URL " ]
    [ "$(env_get .env URL)" = "http://h/{{ token }}" ]
}

# ── .env reading and writing ──────────────────────────────────────────────────

@test "env_get reads values the way compose does" {
    printf 'A={{ a | generate(hex64) }}   # from openssl\r\nB="quoted value" # c\nC=abc#notcomment\nD={{ d }} # get it\nE=\nF=plain\n' > .env
    [ "$(env_get .env A)" = "{{ a | generate(hex64) }}" ]
    [ "$(env_get .env B)" = "quoted value" ]
    [ "$(env_get .env C)" = "abc#notcomment" ]
    [ "$(env_get .env D)" = "{{ d }}" ]
    [ "$(env_get .env E)" = "" ]
    [ "$(env_get .env F)" = "plain" ]
    [ "$(env_get .env MISSING)" = "" ]
}

@test "env_get does not confuse UID with PUID" {
    printf 'PUID=1234\nUID=1000\n' > .env
    [ "$(env_get .env UID)" = "1000" ]
    [ "$(env_get .env PUID)" = "1234" ]
}

@test "env_set keeps the line's comment and quotes special values" {
    printf 'A={{ a | generate(hex64) }}   # from openssl\nD={{ d }} # get it\nX=1\n' > .env
    env_set .env A deadbeef
    env_set .env D 'has space and $dollar'
    grep -qx 'A=deadbeef   # from openssl' .env
    grep -qx "D='has space and \$dollar' # get it" .env
    grep -qx 'X=1' .env
    [ "$(env_get .env D)" = 'has space and $dollar' ]
}

@test "env_set keeps the file's permissions" {
    printf 'A=1\n' > .env; chmod 640 .env
    env_set .env A 2
    [ "$(stat -c %a .env)" = 640 ]
}

@test "sync_env_keys adds only missing keys, even without a final newline" {
    mkdir svc
    printf 'A=1\nB={{ b }}\n# C=commented\nD=4\n' > svc/.env.example
    printf 'A=custom' > svc/.env
    sync_env_keys svc
    [ "$(env_get svc/.env A)" = custom ]
    [ "$(env_get svc/.env B)" = "{{ b }}" ]
    [ "$(env_get svc/.env D)" = 4 ]
    ! grep -q '^C=' svc/.env
    [ "$(grep -c . svc/.env)" -eq 3 ]
}

@test "env_placeholders lists only keys that still have a placeholder" {
    printf 'A=1\nB={{ b | generate(hex64) }}\nC=http://{{ c }}:80\nD=ok\nE={not a placeholder}\n' > .env
    run env_placeholders .env
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "B" ]
    [ "${lines[1]}" = "C" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "fill_env_placeholders changes nothing without a terminal" {
    printf 'B={{ b | generate(hex64) }}\n' > .env
    cp .env before
    fill_env_placeholders .env < /dev/null
    cmp -s .env before
}

@test "confirm_env_complete refuses without a terminal when values are unset" {
    printf 'B={{ b }}\n' > .env
    ! confirm_env_complete .env < /dev/null
    printf 'B=set\n' > .env
    confirm_env_complete .env < /dev/null
}

# ── names and paths ───────────────────────────────────────────────────────────

@test "valid_svc_name accepts service paths and rejects escapes" {
    for n in jellyfin internal/arr-stack my.svc a-b_c; do valid_svc_name "$n"; done
    for n in .. ../etc /etc a/../b .hidden "" "a//b" "a/"; do ! valid_svc_name "$n"; done
}

# ── compose config parsing (canned `docker compose config` output) ────────────

cfg_sample() {
    cat <<'EOF'
name: demo
services:
  web:
    image: alpine:3.20
    ports:
      - mode: ingress
        target: 80
        published: "8099"
        protocol: tcp
      - mode: ingress
        host_ip: 127.0.0.1
        target: 9100
        published: "9100"
        protocol: tcp
    volumes:
      - type: bind
        source: /srv/demo/data/db
        target: /data
        bind: {}
      - type: bind
        source: "/mnt/my media"
        target: /media
        bind: {}
      - type: volume
        source: named
        target: /x
        volume: {}
EOF
}

@test "compose config: project name, ports and bind sources" {
    cfg=$(cfg_sample)
    [ "$(compose_project "$cfg")" = demo ]
    [ "$(cfg_published_ports "$cfg" | tr '\n' ' ')" = "8099 9100 " ]
    run cfg_bind_sources "$cfg"
    [ "${lines[0]}" = "/mnt/my media" ]
    [ "${lines[1]}" = "/srv/demo/data/db" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "port_user names the container using a port, with or without a compose project" {
    # regression: a container started outside compose has an empty project label, and a
    # tab-separated read collapsed it, shifting the fields (reported "a process on this host")
    docker() {
        case "$*" in
            *--filter*) ;;    # this project's own containers: none
            *) printf '%s\n' '|manual-ctr|0.0.0.0:18765->80/tcp, [::]:18765->80/tcp' \
                             'other|other-web-1|0.0.0.0:3080->3080/tcp' \
                             'demo|demo-web-1|0.0.0.0:8099->80/tcp' ;;
        esac
    }
    ss() { :; }
    [ "$(port_user 18765 demo)" = "container manual-ctr" ]
    [ "$(port_user 3080 demo)" = "container other-web-1" ]
    [ -z "$(port_user 8099 demo)" ]     # demo's own port isn't a conflict
    [ -z "$(port_user 9999 demo)" ]
}

@test "data_owner prefers PUID/PGID, then UID/GID" {
    mkdir a b
    printf 'PUID=1234\nPGID=2345\nUID=1\n' > a/.env
    printf 'UID=1000\nGID=1001\n' > b/.env
    [ "$(data_owner a)" = "1234:2345" ]
    [ "$(data_owner b)" = "1000:1001" ]
}

@test "ensure_bind_dirs creates folders with the owner, skips files and system paths" {
    [ "$EUID" -eq 0 ] || skip "needs root (runs as root in the unit-test container)"
    mkdir svc; printf 'PUID=1234\nPGID=2345\n' > svc/.env
    cfg="services:
  x:
    volumes:
      - type: bind
        source: $T/svc/data/db
        target: /db
      - type: bind
        source: $T/svc/conf.yml
        target: /c
      - type: bind
        source: /dev/dri/renderD999
        target: /dev/dri/renderD999"
    run ensure_bind_dirs svc "$cfg"
    [ "$(stat -c %u:%g svc/data)" = "1234:2345" ]
    [ "$(stat -c %u:%g svc/data/db)" = "1234:2345" ]
    [ ! -e svc/conf.yml ]
    [ ! -e /dev/dri/renderD999 ]
    [[ "$output" == *"not creating system paths"* ]]
}

@test "has_media_gpu is false without an Intel/AMD render node" {
    ! has_media_gpu
}

# ── state, update cache, labels ───────────────────────────────────────────────

@test "state_set overwrites and state_get reads" {
    state_set admin alice
    state_set network "static 10.0.0.5/24"
    state_set admin bob
    [ "$(state_get admin)" = bob ]
    [ "$(state_get network)" = "static 10.0.0.5/24" ]
    [ "$(state_get missing)" = "" ]
}

@test "mark_updated changes only the given service and fields" {
    printf 'a\tyes\tyes\t100\nb\tyes\tno\t100\n' > "$UPDATES_FILE"
    mark_updated a no ""
    grep -qx $'a\tno\tyes\t100' "$UPDATES_FILE"
    grep -qx $'b\tyes\tno\t100' "$UPDATES_FILE"
}

@test "update_label wording" {
    [ "$(update_label yes no)" = "new image" ]
    [ "$(update_label yes yes)" = "new image, repo config changed" ]
    [ "$(update_label no no)" = "up to date" ]
    [ "$(update_label unknown unknown)" = "update status unknown" ]
}

@test "config_update_status compares repo files with the installed copy" {
    mkdir -p src/sub dest/sub
    echo a > src/f; echo b > src/sub/g
    cp -r src/. dest/; echo local > dest/.env
    [ "$(config_update_status src dest)" = no ]
    echo changed > src/sub/g
    [ "$(config_update_status src dest)" = yes ]
    [ "$(config_update_status missing dest)" = unknown ]
}

# ── .bashrc blocks ────────────────────────────────────────────────────────────

@test "shell function and completion install once, however often they run" {
    HOME="$T/home"; mkdir -p "$HOME"; printf 'export FOO=1\n' > "$HOME/.bashrc"
    unset SUDO_USER
    for i in 1 2 3; do _install_shell_fn >/dev/null; _install_completion_fn >/dev/null; done
    [ "$(grep -cx '# labber shell function' "$HOME/.bashrc")" -eq 1 ]
    [ "$(grep -cx '# labber completion' "$HOME/.bashrc")" -eq 1 ]
    [ "$(grep -c '^$' "$HOME/.bashrc")" -eq 2 ]
    grep -qx 'export FOO=1' "$HOME/.bashrc"
    bash -c "source '$HOME/.bashrc'; type labber >/dev/null; complete -p labber >/dev/null"
}

# ── sudo ownership ────────────────────────────────────────────────────────────

@test "give_back_files hands repo files to the sudo user but not service data" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    id labbertest &>/dev/null || useradd -m labbertest
    mkdir -p repo/conf dest/data/pg
    echo a > repo/docker-compose.yml; echo b > repo/conf/x.yml
    chown -R 999:999 dest/data/pg; chmod 700 dest/data/pg
    cp -r repo/. dest/
    SUDO_USER=labbertest give_back_files repo dest
    [ "$(stat -c %U dest/docker-compose.yml)" = labbertest ]
    [ "$(stat -c %U dest/conf/x.yml)" = labbertest ]
    [ "$(stat -c %u:%a dest/data/pg)" = "999:700" ]
}

# ── static IP config generation (nothing is applied: setsid is stubbed) ──────

@test "ifupdown: only the IPv4 stanza of the interface changes" {
    setsid() { :; }; ifup() { :; }
    mkdir -p etc
    printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n\nallow-hotplug ens18\niface ens18 inet dhcp\n    hostname vm\n\niface ens18 inet6 auto\n' > etc/interfaces
    # point the function at our copy instead of /etc/network/interfaces
    sed_fn=$(declare -f setup_static_vm | sed "s|/etc/network/interfaces /etc/network/interfaces.d/\*|$T/etc/interfaces|")
    eval "$sed_fn"
    setup_static_vm ens18 192.0.2.20 24 192.0.2.1 ""
    new="$LABBER_STATE_DIR/ip-backup/interfaces.new"
    grep -qx 'iface ens18 inet static' "$new"
    grep -qx '    address 192.0.2.20/24' "$new"
    grep -qx '    gateway 192.0.2.1' "$new"
    grep -qx 'iface ens18 inet6 auto' "$new"
    grep -qx 'iface lo inet loopback' "$new"
    ! grep -q 'inet dhcp' "$new"
    bash -n "$LABBER_STATE_DIR/ip-apply.sh"
    [ "$(state_get network_pending)" = "static 192.0.2.20/24" ]
}

@test "ifupdown: resolv.conf is written after the DHCP client is stopped" {
    # regression: Debian 13's dhcpcd rewrites resolv.conf when its lease is released
    setsid() { :; }; ifup() { :; }
    [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] || skip "needs a plain /etc/resolv.conf"
    mkdir -p etc; printf 'allow-hotplug ens18\niface ens18 inet dhcp\n' > etc/interfaces
    eval "$(declare -f setup_static_vm | sed "s|/etc/network/interfaces /etc/network/interfaces.d/\*|$T/etc/interfaces|")"
    setup_static_vm ens18 192.0.2.20 24 192.0.2.1 "192.0.2.1"
    script="$LABBER_STATE_DIR/ip-apply.sh"
    apply_line=$(grep -m1 "interfaces.new" "$script")
    [[ "$apply_line" == *"dhcpcd -k"* ]]
    # the resolv.conf copy comes after the DHCP release on the same line
    rest="${apply_line#*dhcpcd -k}"
    [[ "$rest" == *"resolv.new"* ]]
}

@test "netplan: generated file is valid YAML with the right values" {
    setsid() { :; }
    netplan() { :; }
    mkdir -p "$T/bin"; printf '#!/bin/sh\n' > "$T/bin/netplan"; chmod +x "$T/bin/netplan"
    PATH="$T/bin:$PATH"
    mkdir -p /etc/netplan 2>/dev/null || skip "can't create /etc/netplan"
    touch /etc/netplan/00-test.yaml
    setup_static_vm ens18 192.0.2.20 24 192.0.2.1 "192.0.2.1 1.1.1.1"
    rm -f /etc/netplan/00-test.yaml
    python3 - "$LABBER_STATE_DIR/ip-backup/netplan.new" <<'EOF'
import sys, yaml
e = yaml.safe_load(open(sys.argv[1]))["network"]["ethernets"]["ens18"]
assert e["dhcp4"] is False
assert e["addresses"] == ["192.0.2.20/24"]
assert e["routes"][0] == {"to": "default", "via": "192.0.2.1"}
assert e["nameservers"]["addresses"] == ["192.0.2.1", "1.1.1.1"]
EOF
}

@test "setup: Docker steps are left out on a non-Docker machine, and the answer is remembered" {
    SETUP_VIRT=lxc
    setup_ask_docker <<< "n" >/dev/null 2>&1
    [ "$SETUP_DOCKER" -eq 0 ]
    [ "$(state_get docker)" = no ]
    ! step_applies docker
    ! step_applies dockerlogs
    step_applies labber
    setup_ask_docker <<< "" >/dev/null 2>&1      # Enter keeps the remembered answer
    [ "$SETUP_DOCKER" -eq 0 ]
    setup_ask_docker <<< "y" >/dev/null 2>&1
    [ "$SETUP_DOCKER" -eq 1 ]
    [ "$(state_get docker)" = yes ]
    step_applies docker
}

@test "setup: always asks about Docker, showing the last answer as the default" {
    command -v script >/dev/null || skip "needs script(1)"
    # read -p only prints its prompt on a terminal, so ask through a pseudo-terminal
    printf 'source "%s"; LABBER_STATE_DIR="%s/state"\nsetup_ask_docker; echo "RESULT=$SETUP_DOCKER"\n' \
        "$LABBER" "$T" > "$T/ask.sh"
    run script -qefc "bash $T/ask.sh" /dev/null <<< ""          # first run: default yes
    [[ "$output" == *"Will this machine run Docker services? [Y/n]"* ]]
    [[ "$output" == *"RESULT=1"* ]]
    state_set docker no
    run script -qefc "bash $T/ask.sh" /dev/null <<< ""          # Enter keeps "no"
    [[ "$output" == *"(last answer: no) [y/N]"* ]]
    [[ "$output" == *"RESULT=0"* ]]
}

@test "setup checklist: answering no to Docker hides the Docker steps" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    command -v script >/dev/null || skip "needs script(1)"
    rm -f /var/lib/labber/setup.state
    # answers: treat as a VM? (the container isn't one) · Docker? no · quit the checklist
    run script -qefc "bash $LABBER setup" /dev/null <<< $'y\nn\nq\n'
    out=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
    echo "$out"
    [[ "$out" == *"Docker steps left out"* ]]
    [[ "$out" == *"system update"* ]]
    [[ "$out" != *"Docker (official repo)"* ]]
    [[ "$out" != *"Docker log rotation"* ]]
    [[ "$out" == *"nothing changed"* ]]
    rm -f /var/lib/labber/setup.state
}

@test "setup: the network step defaults to the last choice" {
    command -v script >/dev/null || skip "needs script(1)"
    [ -n "$(net_iface)" ] || skip "no default route here"
    printf 'source "%s"; LABBER_STATE_DIR="%s/state"; SETUP_VIRT=lxc\nstate_set network_choice 3\nst_network_run\n' \
        "$LABBER" "$T" > "$T/net.sh"
    run script -qefc "bash $T/net.sh" /dev/null <<< ""      # Enter keeps the last choice (3 = skip)
    [[ "$output" == *"choice [3]"* ]]
    [[ "$output" == *"network unchanged"* ]]
}

@test "setup: 'treat it as a VM?' remembers the answer" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    command -v script >/dev/null || skip "needs script(1)"
    rm -f /var/lib/labber/setup.state
    # first run: treat as VM? no (→ LXC) · Docker? Enter · quit
    run script -qefc "bash $LABBER setup" /dev/null <<< $'n\n\nq\n'
    [[ "$output" == *"LXC"* ]]
    # second run: the earlier answer is the default — Enter keeps LXC
    run script -qefc "bash $LABBER setup" /dev/null <<< $'\n\nq\n'
    out=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
    echo "$out"
    [[ "$out" == *"treat it as a VM? (last answer: lxc) [y/N]"* ]]
    [[ "$out" == *", LXC, user:"* ]]
    rm -f /var/lib/labber/setup.state
}

@test "locale_norm matches how locale -a lists locales" {
    [ "$(locale_norm en_US.UTF-8)" = "en_US.utf8" ]
    [ "$(locale_norm de_DE.utf-8)" = "de_DE.utf8" ]
    [ "$(locale_norm C.UTF-8)" = "C.utf8" ]
}

@test "health check: script writes the three metrics, login message shows only problems" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    apt_install() { :; }; systemctl() { :; }
    run st_healthcheck_run
    [ "$status" -eq 0 ]
    bash -n "$HEALTH_BIN"
    f=/var/lib/labber/metrics/labber.prom
    grep -qE '^labber_reboot_required [01]$' "$f"
    grep -qE '^labber_restart_required_services [0-9]+$' "$f"
    grep -qE '^labber_security_updates_pending [0-9]+$' "$f"
    grep -q 'Post-Invoke' /etc/apt/apt.conf.d/99labber-health-check
    # nothing to report → no output
    printf 'labber_reboot_required 0\nlabber_restart_required_services 0\nlabber_security_updates_pending 0\n' > "$f"
    [ -z "$(/etc/update-motd.d/95-labber-health)" ]
    printf 'labber_reboot_required 1\nlabber_restart_required_services 2\nlabber_security_updates_pending 3\n' > "$f"
    run /etc/update-motd.d/95-labber-health
    [[ "$output" == *"Reboot needed"* ]]
    [[ "$output" == *"2 service(s)"* ]]
    [[ "$output" == *"3 security update(s)"* ]]
}

@test "alloy config: URLs, textfile folder and guest labels" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    pkg_installed() { [ "$1" = alloy ]; }; usermod() { :; }; systemctl() { :; }
    alloy() { :; }; curl() { :; }     # config check + readiness probe
    SETUP_VIRT=vm
    printf 'not-a-url\nhttp://mon.example:9090/\n\n' | st_alloy_run >/dev/null 2>&1
    c=/etc/alloy/config.alloy
    grep -q 'managed by labber setup' "$c"
    grep -q 'url = "http://mon.example:9090/api/v1/write"' "$c"
    grep -q 'url = "http://mon.example:3100/loki/api/v1/push"' "$c"    # Loki defaults to the same host
    grep -q "directory = \"$LABBER_METRICS_DIR\"" "$c"
    grep -q 'replacement  = "guest-node-exporters"' "$c"
    grep -q 'replacement  = "vm"' "$c"
    [ "$(state_get alloy_prometheus)" = "http://mon.example:9090" ]
    # VM: full-ish set; systemd services only; the noisy unit states are dropped
    grep -q 'set_collectors = \["cpu", ' "$c"
    grep -q 'unit_include = ".+\\\\.service"' "$c"
    grep -q 'regex         = "node_systemd_unit_state;(active|inactive|activating|deactivating)"' "$c"
    # LXC: no cpu/memory/network (Proxmox reports those), only "/"
    SETUP_VIRT=lxc
    printf '\n\n' | st_alloy_run >/dev/null 2>&1
    grep -q 'set_collectors = \["stat", "filesystem", "systemd", "textfile"\]' "$c"
    grep -q 'mount_points_exclude = "\^/\.+"' "$c"
    grep -q 'replacement  = "lxc"' "$c"
}

@test "completion: zsh gets bashcompinit, bash doesn't" {
    HOME="$T/home"; mkdir -p "$HOME"; touch "$HOME/.bashrc" "$HOME/.zshrc"; unset SUDO_USER
    _install_completion_fn >/dev/null
    grep -q 'bashcompinit' "$HOME/.zshrc"
    ! grep -q 'bashcompinit' "$HOME/.bashrc"
    grep -qx 'complete -F _labber_complete labber' "$HOME/.bashrc"
    grep -qx 'complete -F _labber_complete labber' "$HOME/.zshrc"
}

@test "completion: works the same in bash and zsh" {
    command -v zsh >/dev/null || skip "needs zsh"
    # regression: under zsh's bashcompinit, COMP_CWORD counts from 0 but arrays from 1,
    # so completion read the word before the cursor
    HOME="$T/home"; mkdir -p "$HOME"; touch "$HOME/.bashrc" "$HOME/.zshrc"; unset SUDO_USER
    _install_completion_fn >/dev/null
    cat > "$T/zc.zsh" <<'EOF'
autoload -Uz compinit && compinit -u
source ~/.zshrc
complete_line() {   # mirrors bashcompinit's _bash_complete
  local -a words; words=("$@"); local CURRENT=$#
  local -a COMP_WORDS COMPREPLY; local COMP_CWORD
  (( COMP_CWORD = CURRENT - 1 )); COMP_WORDS=( "${words[@]}" )
  _labber_complete; print -r -- "${COMPREPLY[*]}"
}
print "svc:$(complete_line labber some-svc re)"
print "global:[$(complete_line labber ls x)]"
EOF
    run env HOME="$HOME" zsh "$T/zc.zsh"
    echo "$output"
    [[ "$output" == *"svc:"*"restart"* ]]
    [[ "$output" == *"global:[]"* ]]
    # and bash still works
    run bash -c "source '$HOME/.bashrc'; COMP_WORDS=(labber some-svc re); COMP_CWORD=2; _labber_complete; echo \"\${COMPREPLY[*]}\""
    [[ "$output" == *restart* && "$output" == *rebuild* ]]
}

@test "valid_ipv4" {
    valid_ipv4 198.51.100.1
    valid_ipv4 0.0.0.0
    ! valid_ipv4 256.1.1.1
    ! valid_ipv4 1.2.3
    ! valid_ipv4 a.b.c.d
}

# ── command line ──────────────────────────────────────────────────────────────

@test "help, unknown command and invalid service name" {
    # service commands check for docker/git before anything else; stub them
    mkdir -p "$T/bin"; printf '#!/bin/sh\n' > "$T/bin/docker"; printf '#!/bin/sh\n' > "$T/bin/git"
    chmod +x "$T/bin/docker" "$T/bin/git"; PATH="$T/bin:$PATH"
    run bash "$LABBER" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"labber v"* ]]
    # regression: `curl … | bash -s …` (documented install) once did nothing — piped,
    # BASH_SOURCE and $0 differ
    run bash -c "cat '$LABBER' | bash -s help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"labber v"* ]]
    run bash -c "bash <(cat '$LABBER') help"
    [[ "$output" == *"labber v"* ]]
    run bash "$LABBER" nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command"* ]]
    run bash "$LABBER" ../etc status
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid service name"* ]]
}
