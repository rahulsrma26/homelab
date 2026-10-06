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

@test "placeholder_rule recognises every placeholder form" {
    [ "$(placeholder_rule _changeme_)" = "manual 0" ]
    [ "$(placeholder_rule changeme)" = "manual 0" ]
    [ "$(placeholder_rule _changeme_min_32_)" = "min 32" ]
    [ "$(placeholder_rule _changeme_hex_64_)" = "hex 64" ]
    [ "$(placeholder_rule _changeme_b64_32_)" = "b64 32" ]
    [ "$(placeholder_rule _changeme_md5_)" = "hex 32" ]
    [ "$(placeholder_rule _changeme_sha256_)" = "hex 64" ]
    [ "$(placeholder_rule _changeme_uuid_)" = "uuid 36" ]
    [ "$(placeholder_rule '<telegram-bot-token>')" = "manual 0" ]
    [ "$(placeholder_rule 'https://joplin.<your-domain>')" = "manual 0" ]
}

@test "placeholder_rule ignores real values" {
    [ -z "$(placeholder_rule 8080)" ]
    [ -z "$(placeholder_rule hello)" ]
    [ -z "$(placeholder_rule changeme@example.com)" ]
    [ -z "$(placeholder_rule _changeme_min_)" ]
}

@test "generated values match their rule" {
    [[ "$(rule_generate hex 64)" =~ ^[a-f0-9]{64}$ ]]
    [[ "$(rule_generate min 32)" =~ ^[A-Za-z0-9]{32}$ ]]
    [ "$(rule_generate b64 32 | wc -c)" -eq 44 ]
    rule_valid uuid 36 "$(rule_generate uuid 36)"
}

@test "generated secrets differ each time" {
    [ "$(rule_generate hex 64)" != "$(rule_generate hex 64)" ]
}

@test "rule_valid accepts good input and rejects bad" {
    rule_valid min 16 "abcdefghijklmnop"
    ! rule_valid min 16 "short"
    rule_valid hex 4 "beEF"
    ! rule_valid hex 4 "beefa"
    ! rule_valid hex 4 "zzzz"
    ! rule_valid uuid 36 "not-a-uuid"
    ! rule_valid manual 0 ""
}

# ── .env reading and writing ──────────────────────────────────────────────────

@test "env_get reads values the way compose does" {
    printf 'A=_changeme_hex_64_   # from openssl\r\nB="quoted value" # c\nC=abc#notcomment\nD=_changeme_ # get it\nE=\nF=plain\n' > .env
    [ "$(env_get .env A)" = "_changeme_hex_64_" ]
    [ "$(env_get .env B)" = "quoted value" ]
    [ "$(env_get .env C)" = "abc#notcomment" ]
    [ "$(env_get .env D)" = "_changeme_" ]
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
    printf 'A=_changeme_hex_64_   # from openssl\nD=_changeme_ # get it\nX=1\n' > .env
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
    printf 'A=1\nB=_changeme_\n# C=commented\nD=4\n' > svc/.env.example
    printf 'A=custom' > svc/.env
    sync_env_keys svc
    [ "$(env_get svc/.env A)" = custom ]
    [ "$(env_get svc/.env B)" = _changeme_ ]
    [ "$(env_get svc/.env D)" = 4 ]
    ! grep -q '^C=' svc/.env
    [ "$(grep -c . svc/.env)" -eq 3 ]
}

@test "env_placeholders lists only unset keys" {
    printf 'A=1\nB=_changeme_hex_64_\nC=<token>\nD=ok\n' > .env
    run env_placeholders .env
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "B hex 64" ]
    [ "${lines[1]}" = "C manual 0" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "fill_env_placeholders changes nothing without a terminal" {
    printf 'B=_changeme_hex_64_\n' > .env
    cp .env before
    fill_env_placeholders .env < /dev/null
    cmp -s .env before
}

@test "confirm_env_complete refuses without a terminal when values are unset" {
    printf 'B=_changeme_\n' > .env
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
    run bash "$LABBER" nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command"* ]]
    run bash "$LABBER" ../etc status
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid service name"* ]]
}
