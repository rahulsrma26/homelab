#!/usr/bin/env bats
# Unit tests for labber's functions. No Docker daemon, network or VM needed.
# Run with: tests/labber/run-unit.sh   (or: make test-labber-unit)

setup() {
    LABBER="${LABBER:-$BATS_TEST_DIRNAME/../../labber/labber}"
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
    gen_valid hex4 beEF;  ! gen_valid hex4 beefa || false;  ! gen_valid hex4 zzzz || false
    gen_valid '[A-Za-z0-9],16' 'any chars ok, 16+'; ! gen_valid '[A-Za-z0-9],16' short || false
    ! gen_valid uuid not-a-uuid; ! gen_valid hex4 '' || false
    [ "$(gen_desc hex64)" = "64 hex characters" ]
    [ "$(gen_desc '[A-Za-z0-9],16')" = "at least 16 characters" ]
}

@test "fill: each name asked once, defaults, generated secrets, typed values" {
    command -v script >/dev/null || skip "needs script(1)"
    printf '%s\n' 'S={{ s | generate(hex64) }}' 'P={{ p | generate([A-Za-z0-9],16) }}   # note' \
        'OLD={{ old | generate([A-Za-z0-9],32) }}' \
        'TOKEN={{ token }}' 'URL=http://{{ host }}:{{ port | default(8000) }}/v1' 'URL2=http://{{ host }}/x' 'KEEP=1' > .env
    printf 'source "%s"; set +u\nfill_env_placeholders .env\n' "$LABBER" > fill.sh
    # answers: generate s, p and old? no · s: too short → use anyway? n → asked again · s ·
    # p: Enter → generated · old: an existing 10-character password → use anyway? y ·
    # token · host (asked once) · port: Enter → 8000
    run script -qefc "bash fill.sh" /dev/null <<< $'n\nshort\nn\nbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef\n\nOldPass123\ny\nmy-token\n10.0.0.9\n\n'
    echo "$output"
    [ "$(env_get .env S)" = beefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef ]
    [[ "$(env_get .env P)" =~ ^[A-Za-z0-9]{16}$ ]]
    [ "$(env_get .env OLD)" = OldPass123 ]
    [[ "$output" == *"use it anyway?"* && "$output" == *"old: kept as typed"* ]]
    grep -q '# note' .env
    [ "$(env_get .env TOKEN)" = my-token ]
    [ "$(env_get .env URL)" = "http://10.0.0.9:8000/v1" ]
    [ "$(env_get .env URL2)" = "http://10.0.0.9/x" ]
    [ "$(env_get .env KEEP)" = 1 ]
    [ "$(grep -c 'host (required)' <<< "$output")" -eq 1 ]
    [[ "$output" == *"doesn't meet 64 hex characters"* ]]
    [[ "$output" == *"Generate s p old?"* ]]
    [ -z "$(env_placeholders .env)" ]
}

@test "timezone step: UTC counts as done only once confirmed; real zones always do" {
    current_tz() { echo Etc/UTC; }
    [[ "$(st_hostname_status)" == "todo: timezone Etc/UTC" ]]      # fresh machine: not set yet
    state_set timezone Etc/UTC
    [[ "$(st_hostname_status)" == done:* ]]                         # someone chose UTC
    current_tz() { echo Region/City; }
    [[ "$(st_hostname_status)" == "done: $(hostname), Region/City" ]]
    current_tz() { echo ""; }
    [[ "$(st_hostname_status)" == "todo: timezone unset" ]]
}

@test "timezone step: a zone or hostname given as a flag that differs is still to do" {
    # an installer's zone counts as chosen — unless --timezone says otherwise
    current_tz() { echo Region/City; }
    [[ "$(st_hostname_status)" == done:* ]]
    SETUP_ANS[timezone]=Etc/UTC
    [[ "$(st_hostname_status)" == "todo: timezone Region/City → Etc/UTC" ]]
    current_tz() { echo Etc/UTC; }
    [[ "$(st_hostname_status)" == "done: $(hostname), Etc/UTC" ]]
    SETUP_ANS[hostname]="not-$(hostname)"
    [[ "$(st_hostname_status)" == "todo: hostname $(hostname) → not-$(hostname)" ]]
    SETUP_ANS[hostname]="$(hostname)"
    [[ "$(st_hostname_status)" == done:* ]]
}

@test "choice: values, validation and template parsing" {
    run tpl_list 'COMPOSE_FILE=a.yml:compose.{{ mode | choice(lan, cf) }}.yml'
    [ "$output" = $'mode\tchoice\tlan, cf' ]
    [ "$(choice_values 'lan, cf ,x' | paste -sd' ' -)" = "lan cf x" ]
    choice_known 'lan,cf'
    ! choice_known 'lan' || false
    ! choice_known 'lan,lan' || false
    ! choice_known ' , ' || false
}

@test "fill: choice re-asks on an unknown value, Enter skips" {
    command -v script >/dev/null || skip "needs script(1)"
    printf 'F=docker-compose.yml:compose.{{ mode | choice(lan,cf) }}.yml\nG={{ other | choice(a,b) }}\n' > .env
    printf 'source "%s"; set +u\nfill_env_placeholders .env\n' "$LABBER" > fill.sh
    # answers: mode: "foo" (rejected) then "cf" · other: Enter (skipped)
    run script -qefc "bash fill.sh" /dev/null <<< $'foo\ncf\n\n'
    echo "$output"
    [ "$(env_get .env F)" = "docker-compose.yml:compose.cf.yml" ]
    [[ "$output" == *"mode (lan|cf)"* ]]
    [[ "$output" == *"must be one of: lan|cf"* ]]
    [ "$(env_placeholders .env)" = G ]
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
    ! grep -q '^C=' svc/.env || false
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

@test "env_placeholders skips lines the template doesn't ask (e.g. Paperless's {{ title }} format)" {
    mkdir -p svc
    printf 'A={{ a }}\nB=fixed\n' > svc/.env.example
    printf 'A={{ a }}\nB={{ b }}\nFMT={{ owner_username }}/{{ title }}\n' > svc/.env
    run env_placeholders svc/.env
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "A" ]
    [ "${#lines[@]}" -eq 1 ]
    # without a template next to it: every placeholder, as before
    rm svc/.env.example
    run env_placeholders svc/.env
    [ "${#lines[@]}" -eq 3 ]
}

@test "fill_env_placeholders changes nothing without a terminal" {
    printf 'B={{ b | generate(hex64) }}\n' > .env
    cp .env before
    fill_env_placeholders .env < /dev/null
    cmp -s .env before
}

@test "confirm_env_complete refuses without a terminal when values are unset" {
    printf 'B={{ b }}\n' > .env
    ! confirm_env_complete .env < /dev/null || false
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

@test "port_user reads port ranges: a project's own consecutive ports aren't a conflict" {
    # regression: docker ps shows 8888 and 8889 as 0.0.0.0:8888-8889->8888-8889/tcp, which
    # wasn't recognised, so the project's own ports were reported as "a process on this host"
    docker() {
        case "$*" in
            *--filter*) printf '%s\n' '0.0.0.0:8008->8008/tcp, [::]:8008->8008/tcp, 0.0.0.0:8888-8889->8888-8889/tcp, [::]:8888-8889->8888-8889/tcp' ;;
            *) printf '%s\n' 'ss|soulsync|0.0.0.0:8008->8008/tcp, 0.0.0.0:8888-8889->8888-8889/tcp' \
                             'other|other-1|0.0.0.0:7000-7002->7000-7002/tcp, 9000/tcp' ;;
        esac
    }
    ss() { printf '%s\n' 'LISTEN 0 4096 0.0.0.0:8888 0.0.0.0:*' 'LISTEN 0 4096 [::]:8889 [::]:*' \
                         'LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*' 'LISTEN 0 4096 [::]:18888 [::]:*'; }
    [ -z "$(port_user 8888 ss)" ]
    [ -z "$(port_user 8889 ss)" ]
    [ -z "$(port_user 8008 ss)" ]
    [ "$(port_user 7001 ss)" = "container other-1" ]      # inside another container's range
    [ -z "$(port_user 9000 ss)" ]                          # exposed, not published
    [ "$(port_user 5432 ss)" = "a process on this host" ]
    [ -z "$(port_user 888 ss)" ]  # no partial matches (18888)
    [ -z "$(port_user 1888 ss)" ]
    [ "$(port_user 18888 ss)" = "a process on this host" ]
    [ "$(printf '%s' '0.0.0.0:3080-3081->3080-3081/tcp, :::5030->5030/tcp' | host_ports | paste -sd' ')" = "3080 3081 5030" ]
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
    ! has_media_gpu || false
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

@test "rc blocks: a re-run that changes nothing leaves the files alone and says nothing" {
    HOME="$T/home"; mkdir -p "$HOME"; printf 'export FOO=1\n' > "$HOME/.bashrc"; touch "$HOME/.zshrc"; unset SUDO_USER
    _install_shell_fn >/dev/null; _install_completion_fn >/dev/null
    cp "$HOME/.bashrc" "$T/b0"; cp "$HOME/.zshrc" "$T/z0"
    RC_CHANGED=()
    run _install_shell_fn; [ "$status" -eq 0 ]
    [ -z "$output" ]
    run _install_completion_fn; [ "$status" -eq 0 ]
    [ -z "$output" ]
    _install_shell_fn; _install_completion_fn
    [ "${#RC_CHANGED[@]}" -eq 0 ]
    cmp "$HOME/.bashrc" "$T/b0" && cmp "$HOME/.zshrc" "$T/z0"
}

@test "rc blocks: an old or duplicated block is replaced by one current block" {
    HOME="$T/home"; mkdir -p "$HOME"; unset SUDO_USER
    printf '# labber shell function\nlabber() {\n  /usr/local/bin/labber "$@"\n}\nexport A=1\n\n# labber shell function\nlabber() {\n  old\n}\n' > "$HOME/.bashrc"
    RC_CHANGED=()
    run _install_shell_fn
    [[ "$output" == *"shell function updated in $HOME/.bashrc"* ]]
    _install_shell_fn >/dev/null
    [ "$(grep -cx '# labber shell function' "$HOME/.bashrc")" -eq 1 ]
    ! grep -q old "$HOME/.bashrc" || false
    grep -qx 'export A=1' "$HOME/.bashrc"
    RC_CHANGED=(); run _install_shell_fn; [ -z "$output" ]          # now current
}

@test "rc hint: names the rc of the user's login shell, and only when that one changed" {
    HOME="$T/home"; mkdir -p "$HOME"; unset SUDO_USER
    getent() { echo "u:x:1:1::$HOME:$LOGIN_SHELL"; }
    LOGIN_SHELL=/usr/bin/zsh RC_CHANGED=("$HOME/.bashrc" "$HOME/.zshrc")
    run _rc_hint; [[ "$output" == *"source ~/.zshrc"* ]]
    [[ "$output" != *bashrc* ]]
    LOGIN_SHELL=/bin/bash
    run _rc_hint; [[ "$output" == *"source ~/.bashrc"* ]]
    LOGIN_SHELL=/usr/bin/zsh RC_CHANGED=("$HOME/.bashrc")           # zsh user: a bashrc change doesn't matter
    run _rc_hint; [ -z "$output" ]
    LOGIN_SHELL=/usr/bin/fish
    run _rc_hint; [[ "$output" == *"open a new terminal"* ]]
    RC_CHANGED=()
    run _rc_hint; [ -z "$output" ]
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
    ! grep -q 'inet dhcp' "$new" || false
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
    ! step_applies docker || false
    ! step_applies dockerlogs || false
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
    # the services folder is filled in, no @NAME@ left
    grep -qF "updates=\"$SERVICE_BASE/.labber-updates\"" "$HEALTH_BIN"
    ! grep -q '@[A-Z_]*@' "$HEALTH_BIN" || false
    # nothing to report → no output
    printf 'labber_reboot_required 0\nlabber_restart_required_services 0\nlabber_security_updates_pending 0\n' > "$f"
    [ -z "$(/etc/update-motd.d/95-labber-health)" ]
    printf 'labber_reboot_required 1\nlabber_restart_required_services 2\nlabber_security_updates_pending 3\n' > "$f"
    run /etc/update-motd.d/95-labber-health
    [[ "$output" == *"Reboot needed"* ]]
    [[ "$output" == *"2 service(s)"* ]]
    [[ "$output" == *"3 security update(s)"* ]]
    # runs started together (timer, apt hook, setup) all succeed and leave one file
    rm -f "$f"
    for i in 1 2 3 4 5 6; do "$HEALTH_BIN" & done
    for job in $(jobs -p); do wait "$job"; done
    [ "$(stat -c '%a' "$f")" = "644" ]
    grep -qE '^labber_reboot_required [01]$' "$f"
    [ -z "$(find /var/lib/labber/metrics -name '.labber.prom.*')" ]
    # an older installed script is replaced on the next setup
    systemctl() { [ "$1" = is-enabled ]; }
    [ "$(st_healthcheck_status)" = "done" ]
    echo "# old" >> "$HEALTH_BIN"
    [ "$(st_healthcheck_status)" = "todo: newer check script" ]
}

@test "health check: an updated NVIDIA driver with the old module loaded means reboot (VMs only)" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    apt_install() { :; }; systemctl() { :; }
    st_healthcheck_run >/dev/null
    f=/var/lib/labber/metrics/labber.prom
    # fake a VM with a loaded module and an installed driver version
    stub="$T/stub"; mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/systemd-detect-virt"
    printf '#!/bin/sh\necho "$ON_DISK"\n' > "$stub/modinfo"
    chmod +x "$stub"/*
    echo "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.91.07  Release Build  (dvs-builder@U22)" > "$T/nvidia-version"
    check() { PATH="$stub:$PATH" LABBER_NVIDIA_PROC="$T/nvidia-version" ON_DISK="$1" "$HEALTH_BIN"; }
    check 595.112.07
    grep -qx 'labber_gpu_driver_outdated 1' "$f"
    grep -qx 'labber_reboot_required 1' "$f"
    run /etc/update-motd.d/95-labber-health
    [[ "$output" == *"NVIDIA driver was updated"* ]]
    # same version, or no module on disk to compare with → nothing
    check 595.91.07
    grep -qx 'labber_gpu_driver_outdated 0' "$f"
    check ""
    grep -qx 'labber_gpu_driver_outdated 0' "$f"
    # no NVIDIA module loaded at all → nothing
    PATH="$stub:$PATH" LABBER_NVIDIA_PROC="$T/none" ON_DISK=595.112.07 "$HEALTH_BIN"
    grep -qx 'labber_gpu_driver_outdated 0' "$f"
}

@test "gpu metrics: only with nvidia-smi; nvidia-smi output becomes Prometheus metrics" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    bin=$(mktemp -d)
    # no nvidia-smi: the step isn't offered
    PATH="$bin:/usr/bin:/bin" run step_applies gpu
    [ "$status" -ne 0 ]
    cat > "$bin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in
    -L) echo "GPU 0: Test GPU (UUID: GPU-aaa)" ;;
    *--query-gpu*) echo "0, Test GPU 16GB, GPU-aaa, 37, 12, 11107, 16380, 91, 61.25, 70.00, [N/A], 2100, 8001, 0x0000000000000020" ;;
    *--query-compute-apps*) echo "GPU-aaa, $$, /app/llama-server, 8700" ;;
esac
EOF
    chmod +x "$bin/nvidia-smi"
    PATH="$bin:$PATH" step_applies gpu
    PATH="$bin:$PATH" bash "$LABBER_FILES/gpu-metrics.sh" --once
    f=/var/lib/labber/metrics/gpu.prom
    cat "$f"
    grep -qx 'gpu_metrics_up 1' "$f"
    grep -qx 'gpu_utilization_percent{gpu="0",name="Test GPU 16GB"} 37' "$f"
    grep -qx 'gpu_memory_used_bytes{gpu="0",name="Test GPU 16GB"} 11646533632' "$f"
    grep -qx 'gpu_temperature_celsius{gpu="0",name="Test GPU 16GB"} 91' "$f"
    grep -qx 'gpu_power_watts{gpu="0",name="Test GPU 16GB"} 61.25' "$f"
    grep -qx 'gpu_clock_sm_hertz{gpu="0",name="Test GPU 16GB"} 2100000000' "$f"
    grep -qx 'gpu_thermal_throttle{gpu="0",name="Test GPU 16GB"} 1' "$f"
    grep -qx 'gpu_process_memory_used_bytes{gpu="0",process="llama-server",container=""} 9122611200' "$f"
    ! grep -q '^gpu_fan_percent' "$f" || false      # [N/A] is left out
    # the step installs the script and its service
    systemctl() { :; }
    PATH="$bin:$PATH" run st_gpu_run
    [ "$status" -eq 0 ]
    cmp <(labber_file gpu-metrics.sh) "$GPU_BIN"
    grep -qx "ExecStart=$GPU_BIN" /etc/systemd/system/labber-gpu-metrics.service
    # a failing nvidia-smi still writes the file, with gpu_metrics_up 0
    printf '#!/bin/bash\nexit 9\n' > "$bin/nvidia-smi"
    PATH="$bin:$PATH" bash "$LABBER_FILES/gpu-metrics.sh" --once
    grep -qx 'gpu_metrics_up 0' "$f"
    rm -rf "$bin" "$f" "$GPU_BIN" /etc/systemd/system/labber-gpu-metrics.service
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
    ! grep -q '@[A-Z_]*@' "$c" || false
}

@test "completion: zsh gets bashcompinit, bash doesn't" {
    HOME="$T/home"; mkdir -p "$HOME"; touch "$HOME/.bashrc" "$HOME/.zshrc"; unset SUDO_USER
    _install_completion_fn >/dev/null
    grep -qx 'autoload -U +X bashcompinit && bashcompinit' "$HOME/.zshrc"
    ! grep -q '^autoload .*bashcompinit' "$HOME/.bashrc" || false
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
    ! valid_ipv4 256.1.1.1 || false
    ! valid_ipv4 1.2.3 || false
    ! valid_ipv4 a.b.c.d || false
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

# ── labber's own files and install ────────────────────────────────────────────

# a tarball like GitHub's (<repo>-main/labber/…) of the labber under test → $1
make_bundle() {
    local b="$T/bundle"; rm -rf "$b"; mkdir -p "$b/homelab-main"
    cp -R "$(dirname "$LABBER")" "$b/homelab-main/labber"
    if [ -n "${2:-}" ]; then sed -i "s/^VERSION=.*/VERSION=\"$2\"/" "$b/homelab-main/labber/labber"; fi
    tar -czf "$1" -C "$b" homelab-main
}

@test "labber_file fills in @NAME@ values literally" {
    LABBER_FILES="$T/files"; mkdir -p "$LABBER_FILES"
    printf 'a = "@A@"\nb = "@B@" and "@A@"\nc = "@C@"\n' > "$LABBER_FILES/t.conf"
    run labber_file t.conf A='x&y\1' B='^/(dev|proc)($|/)' C='"q"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'a = "x&y\1"' ]
    [ "${lines[1]}" = 'b = "^/(dev|proc)($|/)" and "x&y\1"' ]
    [ "${lines[2]}" = 'c = ""q""' ]
    run labber_file missing.conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"labber file missing"* ]]
}

@test "labber finds its files/ next to itself, and has none when piped" {
    [ "$LABBER_FILES" = "$(cd "$(dirname "$LABBER")" && pwd -P)/files" ]
    [ -f "$LABBER_FILES/alloy/base.alloy" ]
    run bash -c "source <(cat '$LABBER'); echo \"[\$LABBER_FILES]\""
    [ "$output" = "[]" ]
}

@test "every @NAME@ in labber's files is one labber fills in" {
    # base.alloy: the names st_alloy_run passes; health-check.sh: SERVICE_BASE
    run grep -oh '@[A-Z_]*@' "$LABBER_FILES/alloy/base.alloy"
    [ "$(printf '%s\n' "${lines[@]}" | sort -u | tr '\n' ' ')" = "@AUTH@ @COLLECTORS@ @FS_EXCLUDE@ @LOKI@ @METRICS_DIR@ @PROMETHEUS@ @VIRT@ " ]
    run grep -oh '@[A-Z_]*@' "$LABBER_FILES/health-check.sh"
    [ "$output" = "@SERVICE_BASE@" ]
    ! grep -q '@[A-Z_]*@' "$LABBER_FILES/alloy/docker.alloy" "$LABBER_FILES/motd-health.sh" "$LABBER_FILES/gpu-metrics.sh" || false
}

@test "download + place: installs the folder, links the command, replaces a pre-4.0 file" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    command -v curl >/dev/null || skip "needs curl"
    make_bundle "$T/labber.tar.gz" 9.9.9
    LABBER_URL="file://$T/labber.tar.gz" LABBER_LIB="$T/lib/labber" LABBER_BIN="$T/bin/labber"
    mkdir -p "$T/lib" "$T/bin" "$T/dl"
    printf '#!/bin/bash\nVERSION="3.0.0"\n' > "$LABBER_BIN"     # the old single-file install
    dir=$(labber_download "$T/dl")
    [ "$(labber_version_of "$dir")" = 9.9.9 ]
    labber_place "$dir"
    [ -L "$LABBER_BIN" ]
    [ "$(readlink "$LABBER_BIN")" = "$LABBER_LIB/labber" ]
    [ -x "$LABBER_LIB/labber" ]
    [ -f "$LABBER_LIB/files/alloy/base.alloy" ]
    [ "$(stat -c '%U %a' "$LABBER_LIB/labber")" = "root 755" ]
    [ "$(stat -c '%a' "$LABBER_LIB/files/health-check.sh")" = "644" ]
    run bash "$LABBER_BIN" help
    [[ "$output" == *"labber v9.9.9"* ]]
    # placing again (an update) swaps the folder and leaves nothing behind
    labber_place "$dir"
    [ -f "$LABBER_LIB/labber" ]
    [ ! -e "$LABBER_LIB.new" ]
    [ ! -e "$LABBER_LIB.old" ]
    [ ! -e "$LABBER_BIN.new" ]
    # a bad download is an error, not a half install
    LABBER_URL="file://$T/nothing.tar.gz"
    run labber_download "$(mktemp -d)"
    [ "$status" -ne 0 ]
}

@test "the forwarder at services/labber runs the new labber" {
    command -v curl >/dev/null || skip "needs curl"
    make_bundle "$T/labber.tar.gz"
    fwd="$(dirname "$LABBER")/../services/labber"
    run env LABBER_URL="file://$T/labber.tar.gz" bash "$fwd" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"labber v$VERSION"* ]]
    # old labbers self-update from it: it must carry a version line, and a newer one
    grep -qE '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$fwd"
    run env LABBER_URL="file://$T/nothing.tar.gz" bash "$fwd" help
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not download labber"* ]]
}

# ── corner cases (audit 2026-10) ──────────────────────────────────────────────

@test "env_set sets a key that appears twice everywhere (env_get reads the last)" {
    printf 'A={{ a | default(1) }}\nB=x\nA={{ a | default(1) }}\n' > .env
    env_set .env A 1
    [ "$(grep -c '^A=1$' .env)" -eq 2 ]
    [ "$(env_get .env A)" = 1 ]
    [ -z "$(env_placeholders .env)" ]
}

@test "gen_known rejects generator typos instead of hanging or crashing later" {
    gen_known hex64
    gen_known base64_32
    gen_known uuid
    gen_known '[A-Za-z0-9],16'
    ! gen_known '[z-a],8' || false          # reversed range: tr refuses it
    ! gen_known hex0 || false
    ! gen_known '[A-Z],0' || false
    ! gen_known '[[:space:]],8' || false    # only invisible characters
    run rand_chars 8 'z-a'
    [ "$status" -eq 1 ]
}

@test "update keeps your edits; the repo's newer version goes next to them as .labber-new" {
    mkdir -p repo1/config repo2/config svc
    printf 'a: 1\n' > repo1/config/app.yml; printf 'x\n' > repo1/other.yml; printf 'K=v\n' > repo1/.env.example
    cp -r repo1/. svc/; record_base repo1 svc
    printf 'K=mine\n' > svc/.env
    [ "$(config_update_status repo1 svc)" = no ]
    # you edit app.yml: not an update, and an update with an unchanged repo leaves it alone
    printf 'a: 1\ncameras: mine\n' > svc/config/app.yml
    [ "$(config_update_status repo1 svc)" = no ]
    copy_svc_files repo1 svc 2>/dev/null
    grep -q 'cameras: mine' svc/config/app.yml
    [ ! -e svc/config/app.yml.labber-new ]
    # the repo changes app.yml and other.yml: other.yml (not edited) is updated,
    # app.yml keeps your version and gets .labber-new
    printf 'a: 2\n' > repo2/config/app.yml; printf 'y\n' > repo2/other.yml; printf 'K=v\nN=1\n' > repo2/.env.example
    [ "$(config_update_status repo2 svc)" = yes ]
    run copy_svc_files repo2 svc
    [[ "$output" == *"kept your edits"*"config/app.yml"* ]]
    grep -q 'cameras: mine' svc/config/app.yml
    [ "$(cat svc/config/app.yml.labber-new)" = 'a: 2' ]
    [ "$(cat svc/other.yml)" = y ]
    [ "$(cat svc/.env)" = 'K=mine' ]
    grep -q '^N=1$' svc/.env.example
    [ "$(config_update_status repo2 svc)" = no ]
    # reinstall: the repo wins, your version is kept as .labber-bak
    run copy_svc_files repo2 svc reinstall
    [[ "$output" == *"saved as .labber-bak"* ]]
    [ "$(cat svc/config/app.yml)" = 'a: 2' ]
    grep -q 'cameras: mine' svc/config/app.yml.labber-bak
}

@test "update of a service installed before .labber-base: differing files are kept, not overwritten" {
    mkdir -p repo svc
    printf 'new\n' > repo/app.yml; printf 'old-or-edited\n' > svc/app.yml
    [ "$(config_update_status repo svc)" = yes ]
    copy_svc_files repo svc 2>/dev/null
    [ "$(cat svc/app.yml)" = old-or-edited ]
    [ "$(cat svc/app.yml.labber-new)" = new ]
    [ -f svc/.labber-base ]
}

# a repo with history: services/demo/app.yml was v1, is v2 now. Sets REPO; $SRC = a fresh
# fetch of services/ (like an update), with services/demo inside
history_repo() {
    git init -q "$T/hist"; mkdir -p "$T/hist/services/demo"
    gc() { git -C "$T/hist" add -A && git -C "$T/hist" -c user.name=t -c user.email=t@t commit -qm "$1"; }
    printf 'v: 1\n' > "$T/hist/services/demo/app.yml"; printf 'x\n' > "$T/hist/services/demo/other.yml"; gc one
    printf 'v: 2\n' > "$T/hist/services/demo/app.yml"; gc two
    REPO="file://$T/hist"; CLONE_RETRY_DELAY=0
    SRC=$(clone_repo_dir services/)/services/demo
}

@test "update before .labber-base: a file that is an old repo version is replaced, not kept" {
    history_repo
    mkdir svc; printf 'v: 1\n' > svc/app.yml; printf 'x\n' > svc/other.yml     # installed at v1, no record
    run copy_svc_files "$SRC" svc
    [ "$status" -eq 0 ]
    [ "$(cat svc/app.yml)" = 'v: 2' ]
    [ ! -e svc/app.yml.labber-new ]
    [[ "$output" != *"kept your edits"* ]]
    [ -z "$(find /tmp -maxdepth 1 -name 'homelab-history-*' -newer "$T" 2>/dev/null)" ]   # history clone removed
}

@test "update before .labber-base: a real local edit (in no repo version) is still kept" {
    history_repo
    mkdir svc; printf 'v: 1\nmine: yes\n' > svc/app.yml
    run copy_svc_files "$SRC" svc
    grep -q 'mine: yes' svc/app.yml
    [ "$(cat svc/app.yml.labber-new)" = 'v: 2' ]
    [[ "$output" == *"kept your edits"* ]]
}

@test "update in a terminal asks about an edited file the repo changed: repo's, keep, cancel" {
    history_repo
    interactive() { true; }
    setup_svc() { rm -rf svc; mkdir svc; printf 'v: 1\nmine: yes\n' > svc/app.yml; printf 'x\n' > svc/other.yml; }
    # r: the repo's version, yours saved as .labber-bak
    setup_svc; run copy_svc_files "$SRC" svc <<< r
    [ "$status" -eq 0 ]
    [ "$(cat svc/app.yml)" = 'v: 2' ]
    grep -q 'mine: yes' svc/app.yml.labber-bak
    [[ "$output" == *"+v: 2"* ]]                                   # it showed the diff
    # k: yours stays, the repo's goes next to it
    setup_svc; run copy_svc_files "$SRC" svc <<< k
    [ "$status" -eq 0 ]
    grep -q 'mine: yes' svc/app.yml
    [ "$(cat svc/app.yml.labber-new)" = 'v: 2' ]
    # c (and plain Enter): cancelled before anything was touched
    for a in c ''; do
        setup_svc; printf 'x2\n' > "$SRC/other.yml"               # a change that must NOT be applied either
        run copy_svc_files "$SRC" svc <<< "$a"
        [ "$status" -eq 2 ]
        [[ "$output" == *"cancelled"* ]]
        grep -q 'mine: yes' svc/app.yml
        [ "$(cat svc/other.yml)" = x ]
        [ ! -e svc/app.yml.labber-new ]
        [ ! -e svc/.labber-base ]
    done
}

@test "setup --prometheus/--loki: Alloy's URLs without questions; bad input refused" {
    ask() { echo "ASKED" >&2; echo ""; }          # any question would show up here
    SETUP_PROM="" SETUP_LOKI=""
    setup_args --prometheus http://mon.example:9090/ --loki http://mon.example:3100
    run alloy_urls; [ "$status" -eq 0 ]; [[ "$output" != *ASKED* ]]
    alloy_urls; [ "$ALLOY_PROM" = http://mon.example:9090 ]
    [ "$ALLOY_LOKI" = http://mon.example:3100 ]
    # --prometheus alone: Loki on the same host, port 3100, still no question
    SETUP_PROM="" SETUP_LOKI=""; setup_args --prometheus http://10.9.9.9:9090
    run alloy_urls; [[ "$output" != *ASKED* ]]; alloy_urls; [ "$ALLOY_LOKI" = http://10.9.9.9:3100 ]
    # nothing given: asked as before (Enter on the Prometheus question = skip)
    SETUP_PROM="" SETUP_LOKI=""; run alloy_urls; [ "$status" -eq 1 ]; [[ "$output" == *ASKED* ]]
    # refused: not a URL, a missing value, an unknown option
    run setup_args --prometheus mon:9090; [ "$status" -ne 0 ]; [[ "$output" == *"needs an http"* ]]
    run setup_args --loki; [ "$status" -ne 0 ]
    run setup_args --promethus http://x:9090; [ "$status" -ne 0 ]; [[ "$output" == *"unknown setup option"* ]]
}

@test "setup flags: each answers its question; --yes never reads; bad values refused" {
    ask_read=0; read() { ask_read=1; command read "$@"; }       # a keyboard read would set this
    SETUP_YES=0; SETUP_ANS=(); SETUP_WITH="" SETUP_WITHOUT=""
    setup_args --docker no --admin ops --hostname box1 --timezone Etc/GMT-1 --locale de_DE.UTF-8 \
        --ssh-key 'ssh-ed25519 AAAAC3Nza test' --swap 2 --network skip --virt lxc --with fail2ban,nfs --without zsh
    [ "${SETUP_ANS[docker]}" = no ]
    [ "${SETUP_ANS[admin]}" = ops ]
    [ "${SETUP_ANS[timezone]}" = Etc/GMT-1 ]
    [ "${SETUP_ANS[network]}" = 3 ]
    [ "${SETUP_ANS[swap]}" = 2 ]
    [[ " $SETUP_WITH " == *" fail2ban nfs "* && " $SETUP_WITH " == *" network "* && " $SETUP_WITH " == *" swap "* ]]
    [ "$(echo $SETUP_WITHOUT)" = zsh ]
    # a flag answers without asking, even without --yes
    [ "$(answer hostname "hostname" old </dev/null 2>/dev/null)" = box1 ]
    [ "$ask_read" = 0 ]
    # --yes: no flag → the default, without reading
    SETUP_YES=1; [ "$(answer nothing "q" dflt </dev/null 2>/dev/null)" = dflt ]
    [ "$ask_read" = 0 ]
    yesno "q?" y </dev/null 2>/dev/null; ! yesno "q?" n </dev/null 2>/dev/null || false; [ "$ask_read" = 0 ]
    # refused, with a message
    for bad in "--docker maybe" "--swap 4" "--network static" "--virt docker" "--admin root" "--timezone Mars/Base" \
               "--ssh-key notakey" "--with fail2ban,nosuchstep" "--admin" "--frobnicate x"; do
        run setup_args $bad; [ "$status" -ne 0 ] || { echo "accepted: $bad"; false; }
    done
}

@test "a global command after a word is refused, not run as if the word weren't there" {
    run labber_main tools ls
    [ "$status" -ne 0 ]
    [[ "$output" == *"'ls' takes no service name ('tools')"*"labber tool ls"* ]]
    run labber_main somesvc check-updates
    [ "$status" -ne 0 ]
    [[ "$output" == *"'check-updates' takes no service name ('somesvc')"* ]]
}

@test "ls -r: the repo's services (installed ones marked) and tools, with descriptions" {
    git init -q "$T/origin"; mkdir -p "$T/origin/services/alpha" "$T/origin/services/beta" "$T/origin/tools/gamma" "$T/origin/tools/zsh"
    printf 'image: x\n' > "$T/origin/services/alpha/docker-compose.yml"; printf '# alpha\n\nAlpha does things.\n' > "$T/origin/services/alpha/README.md"
    printf 'services:\n  b:\n    image: example/beta:1\n' > "$T/origin/services/beta/docker-compose.yml"
    printf '#!/usr/bin/env bash\n# Gamma — a handy tool\necho hi\n' > "$T/origin/tools/gamma/install.sh"
    echo cfg > "$T/origin/tools/zsh/p10k.zsh"                       # a folder without install.sh: not a tool
    git -C "$T/origin" add -A && git -C "$T/origin" -c user.name=t -c user.email=t@t commit -qm init
    LABBER_REPO="file://$T/origin"; CLONE_RETRY_DELAY=0
    SERVICE_BASE="$T/svcs"; mkdir -p "$SERVICE_BASE/alpha" && touch "$SERVICE_BASE/alpha/docker-compose.yml"
    run labber_main ls --remote
    [ "$status" -eq 0 ]
    out=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")
    [[ "$out" == *"● alpha"*"Alpha does things"* ]]                 # installed here, README's prose line
    grep -qE '^    beta +image: example/beta:1$' <<< "$out"         # not installed, no README: its image
    grep -qE '^    gamma +Gamma — a handy tool$' <<< "$out"         # a tool, its header comment
    ! grep -qE '^    zsh' <<< "$out" || false                            # config folders aren't listed as tools
    run labber_main ls -x; [ "$status" -ne 0 ]
}

@test "tool: ls lists folders with install.sh; runs it from its folder; refuses bad names and reports failures" {
    git init -q "$T/origin"; mkdir -p "$T/origin/tools/gamma" "$T/origin/tools/zsh" "$T/origin/tools/bad" "$T/origin/scripts/x"
    printf '#!/usr/bin/env bash\n# Gamma — a handy tool\ncat data.txt > "%s/ran"\n' "$T" > "$T/origin/tools/gamma/install.sh"
    echo gamma-data > "$T/origin/tools/gamma/data.txt"             # a file next to install.sh
    printf '#!/usr/bin/env bash\nexit 3\n' > "$T/origin/tools/bad/install.sh"
    echo cfg > "$T/origin/tools/zsh/p10k.zsh"
    printf '#!/usr/bin/env bash\ntouch "%s/escaped"\n' "$T" > "$T/origin/scripts/x/install.sh"
    git -C "$T/origin" add -A && git -C "$T/origin" -c user.name=t -c user.email=t@t commit -qm init
    REPO="file://$T/origin"; CLONE_RETRY_DELAY=0
    run do_tool ls
    [ "$status" -eq 0 ]
    out=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")
    grep -qE '^  gamma +Gamma — a handy tool$' <<< "$out"
    grep -qE '^  bad +$' <<< "$out"                                 # no header comment: name only
    ! grep -q zsh <<< "$out" || false
    run do_tool gamma
    [ "$status" -eq 0 ]
    [ "$(cat "$T/ran")" = gamma-data ]
    run do_tool bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad: install.sh failed (exit 3)"* ]]
    run do_tool zsh
    [ "$status" -ne 0 ]
    [[ "$output" == *"tool 'zsh' not found"* ]]
    for n in ../scripts/x . .. 'a/b' '-x' ''; do run do_tool "$n"; [ "$status" -ne 0 ]; done
    [ ! -e "$T/escaped" ]
}

@test "tool: an empty tools/ says so instead of failing" {
    git init -q "$T/origin"; mkdir -p "$T/origin/tools/zsh"; echo cfg > "$T/origin/tools/zsh/p10k.zsh"
    git -C "$T/origin" add -A && git -C "$T/origin" -c user.name=t -c user.email=t@t commit -qm init
    REPO="file://$T/origin"; CLONE_RETRY_DELAY=0
    run do_tool ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"no tools found"* ]]
}

@test "preflight creates .env from .env.example when there's none yet" {
    mkdir svc; printf 'K=1\n' > svc/.env.example
    sync_env_keys svc >/dev/null
    [ "$(cat svc/.env)" = 'K=1' ]
}

@test "piped install (curl … | bash -s install) finishes, with tab completion" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    command -v curl >/dev/null || skip "needs curl"
    make_bundle "$T/labber.tar.gz"
    mkdir -p "$T/home"; touch "$T/home/.bashrc"
    run bash -c "cat '$LABBER' | LABBER_URL='file://$T/labber.tar.gz' HOME='$T/home' bash -s install"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx '# labber completion' "$T/home/.bashrc"
    # again, with labber already installed: no terminal to ask, so it reinstalls
    run bash -c "cat '$LABBER' | LABBER_URL='file://$T/labber.tar.gz' HOME='$T/home' bash -s install"
    [ "$status" -eq 0 ]
    [[ "$output" == *"labber installed"* ]]
}

@test "labber_place keeps the old install when the new one can't be copied" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    LABBER_LIB="$T/lib/labber" LABBER_BIN="$T/bin/labber"; mkdir -p "$T/lib" "$T/bin"
    labber_place "$(dirname "$LABBER")"
    run labber_place "$T/no-such-dir"
    [ "$status" -eq 1 ]
    [ -f "$LABBER_LIB/labber" ]
    [ -d "$LABBER_LIB/files" ]
    [ ! -e "$LABBER_LIB.new" ]
    [ ! -e "$LABBER_LIB.old" ]
}

@test "check-updates results stay writable for the services folder's owner, even after a run as root" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    id labbertest >/dev/null 2>&1 || useradd -M labbertest
    # (bats' temp dir isn't reachable for other users)
    SERVICE_BASE=$(mktemp -d /tmp/labber-svc-XXXXXX); UPDATES_FILE="$SERVICE_BASE/.labber-updates"
    chown labbertest: "$SERVICE_BASE"; chmod 755 "$SERVICE_BASE"
    # as root (sudo labber check-updates): the file goes to the folder's owner
    printf 'svc\tyes\tno\t1\n' | write_updates_file
    [ "$(stat -c %U "$UPDATES_FILE")" = labbertest ]
    # an old root-owned file (from before this fix) can still be replaced by the owner
    chown root: "$UPDATES_FILE"
    runuser -u labbertest -- bash -c "source '$LABBER'; SERVICE_BASE='$SERVICE_BASE' UPDATES_FILE='$UPDATES_FILE'; mark_updated svc no no"
    [ "$(cat "$UPDATES_FILE")" = "$(printf 'svc\tno\tno\t1')" ]
    [ "$(stat -c %U "$UPDATES_FILE")" = labbertest ]
    [ -z "$(ls -A "$SERVICE_BASE" | grep -v '^\.labber-updates$' || true)" ]    # no temp files left
    rm -rf "$SERVICE_BASE"
}

# ── fetching the repo ─────────────────────────────────────────────────────────

make_repo() {   # a local git repo with services/<name>/, served as file://
    git init -q "$T/origin"
    mkdir -p "$T/origin/services/demo" && echo x > "$T/origin/services/demo/f"
    git -C "$T/origin" add -A && git -C "$T/origin" -c user.name=t -c user.email=t@t commit -qm init
    REPO="file://$T/origin"
}

@test "clone_repo_dir fetches just the asked-for folder" {
    make_repo; CLONE_RETRY_DELAY=0
    dir=$(clone_repo_dir services/) && [ -f "$dir/services/demo/f" ]
    rm -rf "$dir"
}

@test "clone_repo_dir retries a failed fetch (a network hiccup isn't a failure)" {
    make_repo; CLONE_RETRY_DELAY=0
    git() { if [[ "$1" == clone && ! -f "$T/failed-once" ]]; then touch "$T/failed-once"; echo "fatal: unable to access: timeout" >&2; return 128; fi; command git "$@"; }
    run clone_repo_dir services/
    [ "$status" -eq 0 ]
    [ -f "$T/failed-once" ]
    [[ "$output" == *"retrying"* ]]
    [ -f "${lines[-1]}/services/demo/f" ]
}

@test "clone_repo_dir gives up after 3 attempts, with git's reason" {
    CLONE_RETRY_DELAY=0; REPO="file://$T/nowhere"
    run clone_repo_dir services/
    [ "$status" -eq 1 ]
    [ "$(grep -c retrying <<<"$output")" -eq 2 ]
    [[ "$output" == *"could not fetch file://$T/nowhere:"*"repository"* ]]
    [ -z "$(find /tmp -maxdepth 1 -name 'homelab-deploy-*' -newer "$T" 2>/dev/null)" ]   # no temp dirs left
}

@test "check_env_pins: a version left in .env that overrides the template's pin is named, never removed silently" {
    d="$T/svc/demo"; mkdir -p "$d"
    printf 'services:\n  app:\n    image: example/app:${APP_VERSION:-1.2.3}\n  b:\n    build: .\n    image: local:${LOCAL_VERSION:-v1}\n  c:\n    image: example/c:${C_VERSION:-2.0}\n' > "$d/docker-compose.yml"
    printf 'PORT=1\nLOCAL_VERSION=v1\n' > "$d/.env.example"
    printf 'PORT=1\nAPP_VERSION=latest\nLOCAL_VERSION=v2\nC_VERSION=\n' > "$d/.env"
    run check_env_pins "$d" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"APP_VERSION=latest (the template pins 1.2.3)"* ]]     # stale: named, with the pin
    [[ "$output" != *"LOCAL_VERSION"* ]]                                     # still a template setting
    [[ "$output" != *"C_VERSION"* ]]                                         # empty: the pin applies
    [[ "$output" == *"delete APP_VERSION from $d/.env"* ]]
    grep -qx 'APP_VERSION=latest' "$d/.env"                                  # not removed without asking
    printf 'PORT=1\nLOCAL_VERSION=v2\n' > "$d/.env"
    run check_env_pins "$d" </dev/null
    [ -z "$output" ]
}

@test "fill_env_placeholders without a terminal: defaults filled in, anything needing an answer left" {
    e="$T/env"
    printf 'A={{ a | default(telegram) }}\nB={{ b | default() }}\nC={{ c }}\nD={{ d | choice(x,y) }}\nE={{ e | generate(hex64) }}\nF=keep\nG=http://{{ g_host }}:{{ g_port | default(80) }}\n' > "$e"
    run fill_env_placeholders "$e" </dev/null
    [ "$status" -eq 0 ]
    [ "$(env_get "$e" A)" = telegram ]
    [ "$(env_get "$e" B)" = "" ]
    [ "$(env_get "$e" C)" = "{{ c }}" ]                       # required: stays for a terminal
    [ "$(env_get "$e" D)" = "{{ d | choice(x,y) }}" ]         # a choice: stays
    [ "$(env_get "$e" E)" = "{{ e | generate(hex64) }}" ]     # a secret: never made without asking
    [ "$(env_get "$e" F)" = keep ]
    [ "$(env_get "$e" G)" = "http://{{ g_host }}:80" ]        # the default part of a mixed value
    [[ "$output" == *"filled in the defaults of a b g_port"* ]]
    [[ "$output" == *"4 unset value(s)"* ]]
}

# ── A5: hardening ─────────────────────────────────────────────────────────────

@test "env_set/env_get: a value with both ' and \$ (and \\ and \") round-trips" {
    printf 'K=old\n' > "$T/.env"
    for v in "it's \$HOME" 'a\b "q" it'"'"'s $X' "plain" "has space" "\$only"; do
        env_set "$T/.env" K "$v"
        [ "$(env_get "$T/.env" K)" = "$v" ]
    done
    env_set "$T/.env" K "it's \$HOME"
    grep -qx 'K="it'"'"'s \\$HOME"' "$T/.env"
}

@test "rand_chars and gen_valid read lengths as base 10 (hex064 is 64, not octal)" {
    v=$(gen_value hex064); [ "${#v}" -eq 64 ]
    gen_valid hex064 "$v"
    v=$(gen_value '[a-z],010'); [ "${#v}" -eq 10 ]
    gen_valid '[a-z],010' "$v"
    run rand_chars 08x 'a-z'
    [ "$status" -ne 0 ]
}

@test "secret_name: secret-looking placeholders are read hidden" {
    for n in db_password API_KEY telegram_bot_token client_secret private_key smtp_passwd; do secret_name "$n"; done
    for n in domain host port owner_username timezone keyboard; do ! secret_name "$n"; done
}

@test "sync_lock fails closed: no lock, no change" {
    SYNC_LOCK="$T/lockdir"; mkdir "$SYNC_LOCK"          # a folder can't be opened as the lock
    unset LABBER_SYNC_LOCKED
    run sync_lock
    [ "$status" -ne 0 ]
    [[ "$output" == *"can't open the guest's lock"* ]]
    # and every command that changes something takes it (stop here; the lock fails first)
    export LABBER_SYNC_LOCK="$SYNC_LOCK"
    run bash "$LABBER" demo stop
    [ "$status" -ne 0 ]
    [[ "$output" == *"can't open the guest's lock"* ]]
    run bash "$LABBER" help
    [ "$status" -eq 0 ]
}

@test "sync_lock: a free lock is taken, made group-writable, and a held one is waited for" {
    SYNC_LOCK="$T/lock"; unset LABBER_SYNC_LOCKED
    ( sync_lock; [ "$LABBER_SYNC_LOCKED" = 1 ] )
    [ "$(stat -c %a "$SYNC_LOCK")" = 664 ]
    flock "$SYNC_LOCK" sleep 3 &
    sleep 0.5
    start=$(date +%s)
    ( sync_lock ) >/dev/null
    [ $(( $(date +%s) - start )) -ge 2 ]
    wait
}

@test "state_paths: only the instance, its volumes and its bind mounts; never a mount point" {
    d="$T/svc"; mkdir -p "$d/data" "$T/outside/db"
    MNT=$(findmnt -rn -o TARGET | awk -F/ 'NF >= 3' | head -1)     # a real mount point, two levels down
    [ -n "$MNT" ]
    compose_cfg() { printf '    volumes:\n      - type: bind\n        source: %s\n        target: /db\n      - type: bind\n        source: %s\n        target: /p\n' "$T/outside" "$(dirname "$MNT")"; }
    printf 'state: [./data]\n' > "$d/labber.yml"
    run state_paths "$d"; [ "$status" -eq 0 ]
    [ "$output" = "$d/data" ]
    printf 'state: ["${DB}/db"]\nX\n' > "$d/labber.yml"; printf 'DB=%s\n' "$T/outside" > "$d/.env"
    run state_paths "$d"; [ "$status" -eq 0 ]
    [ "$output" = "$T/outside/db" ]
    printf 'DB=%s\n' "$T/elsewhere" > "$d/.env"; mkdir -p "$T/elsewhere/db"
    run state_paths "$d"; [ "$status" -ne 0 ]
    [[ "$output" == *"outside $d"* ]]
    printf 'state: [%s]\n' "$MNT" > "$d/labber.yml"
    run state_paths "$d"; [ "$status" -ne 0 ]
    [[ "$output" == *"mount point"* ]]
}

@test "backups: kept under the backup folder (not /tmp), .env included and restored" {
    export LABBER_BAK_DIR="$T/baks"
    src="$T/src"; dest="$T/dest"; mkdir -p "$src" "$dest"
    printf 'new\n' > "$src/compose.yml"; printf 'old\n' > "$dest/compose.yml"; printf 'K=1\n' > "$dest/.env"
    bak=$(backup_svc_files "$src" "$dest")
    [[ "$bak" == "$T/baks/rollback-"* ]]
    [ "$(stat -c %a "$T/baks")" = 700 ]
    printf 'K=2\n' > "$dest/.env"; cp "$src/compose.yml" "$dest/compose.yml"
    restore_svc_files "$bak" "$dest" >/dev/null
    [ "$(cat "$dest/.env")" = K=1 ]
    [ "$(cat "$dest/compose.yml")" = old ]
}

@test "copies never write through a planted symlink" {
    src="$T/src"; dest="$T/dest"; mkdir -p "$src/conf" "$dest" "$T/target"
    printf 'repo\n' > "$src/conf/a.txt"; printf 'repo\n' > "$src/b.txt"
    ln -s "$T/target" "$dest/conf"                       # a folder leading out
    run copy_svc_files "$src" "$dest" install
    [ "$status" -ne 0 ]
    [ ! -e "$T/target/a.txt" ]
    rm "$dest/conf"; mkdir "$dest/conf"
    rm -f "$dest/b.txt"; printf 'secret\n' > "$T/victim"; ln -s "$T/victim" "$dest/b.txt"   # a file link
    inside "$dest" b.txt
    safe_cp "$src/b.txt" "$dest/b.txt"
    [ "$(cat "$T/victim")" = secret ]
    [ ! -L "$dest/b.txt" ]
    [ "$(cat "$dest/b.txt")" = repo ]
    # a regular file is written in place (same inode): no need to write its folder
    ino=$(stat -c %i "$dest/b.txt"); printf 'new\n' > "$src/b.txt"
    safe_cp "$src/b.txt" "$dest/b.txt"
    [ "$(stat -c %i "$dest/b.txt")" = "$ino" ]
}

@test "target_home works without HOME (systemd: labber sync's self-update)" {
    run env -u HOME -u SUDO_USER bash -c "source '$LABBER'; set +u; target_home"
    [ "$status" -eq 0 ]
    [ "$output" = "$(getent passwd "$(id -u)" | cut -d: -f6)" ]
}

# ── the no-backup disk (/opt/generated) ───────────────────────────────────────

@test "generated_dir: the service's folder on the disk, else ./generated; filled without a terminal" {
    mkdir -p "$T/svc/paperless" && cd "$T/svc/paperless"
    printf 'M={{ models_dir | generated_dir(models) }}\nC={{ c | generated_dir(cache/thumbs) }}\nX=keep\n' > .env
    generated_mounted() { return 1; }
    run fill_env_placeholders "$PWD/.env" </dev/null
    [ "$status" -eq 0 ]
    [ "$(env_get .env M)" = ./generated/models ]
    [ "$(env_get .env C)" = ./generated/cache/thumbs ]
    [ "$(env_get .env X)" = keep ]
    printf 'M={{ models_dir | generated_dir(models) }}\n' > .env
    GEN_DIR="$T/gen"; generated_mounted() { return 0; }
    run fill_env_placeholders "$PWD/.env" </dev/null
    [ "$(env_get .env M)" = "$T/gen/services/paperless/models" ]
    # never changed once set: a disk added later doesn't move a service's files
    run fill_env_placeholders "$PWD/.env" </dev/null
    [ "$(env_get .env M)" = "$T/gen/services/paperless/models" ]
}

@test "generated_dir: only a relative folder of plain names" {
    for s in models cache/thumbs a.b_c-d x/y.z; do generated_sub_ok "$s"; done
    for s in "" /abs ../up a/../b ./a a/./b "a b" 'a$b' .hidden a//b a/; do ! generated_sub_ok "$s"; done
    printf 'B={{ b | generated_dir(../etc) }}\n' > .env
    run fill_env_placeholders "$PWD/.env" </dev/null
    [ "$(env_get .env B)" = "{{ b | generated_dir(../etc) }}" ]
    [[ "$output" == *"needs a relative folder name"* ]]
}

@test "generated_dir: tpl_list knows it; asked interactively like a default" {
    command -v script >/dev/null || skip "needs script(1)"
    run tpl_list '{{ m | generated_dir(models) }}'
    [ "$output" = "m	generated_dir	models" ]
    mkdir -p "$T/svc/llm" && cd "$T/svc/llm"
    printf 'M={{ m | generated_dir(models) }}\nN={{ n | generated_dir(other) }}\n' > .env
    printf 'source "%s"; set +u\ngenerated_mounted() { return 1; }\nfill_env_placeholders "$PWD/.env"\n' "$LABBER" > fill.sh
    run script -qefc "bash fill.sh" /dev/null <<< $'\n/srv/models\n'
    [[ "$output" == *"m [./generated/models]"* ]]
    [ "$(env_get .env M)" = ./generated/models ]
    [ "$(env_get .env N)" = /srv/models ]
}

lsblk_fixture() {   # a VM: root disk, an empty disk, an unmounted ext4, LVM, swap, ZFS, a CD-ROM, ...
    cat <<'JSON'
{"blockdevices":[
 {"name":"sr0","path":"/dev/sr0","type":"rom","size":1073741312,"fstype":null,"pttype":null,"label":null,"uuid":null,"mountpoints":[null],"ro":true,"rm":true},
 {"name":"vda","path":"/dev/vda","type":"disk","size":68719476736,"fstype":null,"pttype":"gpt","label":null,"uuid":null,"mountpoints":[null],"ro":false,"rm":false,
  "children":[{"name":"vda1","path":"/dev/vda1","type":"part","size":1048576000,"fstype":"vfat","pttype":"gpt","label":null,"uuid":"AB-CD","mountpoints":["/boot/efi"],"ro":false,"rm":false},
              {"name":"vda2","path":"/dev/vda2","type":"part","size":60000000000,"fstype":"ext4","pttype":"gpt","label":null,"uuid":"root-uuid","mountpoints":["/"],"ro":false,"rm":false},
              {"name":"vda3","path":"/dev/vda3","type":"part","size":4000000000,"fstype":"ext4","pttype":"gpt","label":"spare","uuid":"spare-uuid","partuuid":"p-spare","mountpoints":[null],"ro":false,"rm":false},
              {"name":"vda4","path":"/dev/vda4","type":"part","size":2000000000,"fstype":"swap","pttype":"gpt","label":null,"uuid":"swap-uuid","mountpoints":["[SWAP]"],"ro":false,"rm":false}]},
 {"name":"vdb","path":"/dev/vdb","type":"disk","size":274877906944,"fstype":null,"pttype":null,"label":null,"uuid":null,"mountpoints":[null],"ro":false,"rm":false},
 {"name":"vdc","path":"/dev/vdc","type":"disk","size":107374182400,"fstype":"ext4","pttype":null,"label":"generated","uuid":"gen-uuid","mountpoints":[null],"ro":false,"rm":false},
 {"name":"vdd","path":"/dev/vdd","type":"disk","size":107374182400,"fstype":"LVM2_member","pttype":null,"label":null,"uuid":"lvm-uuid","mountpoints":[null],"ro":false,"rm":false,
  "children":[{"name":"vg-lv","path":"/dev/mapper/vg-lv","type":"lvm","size":107374182400,"fstype":"ext4","pttype":null,"label":null,"uuid":"lv-uuid","mountpoints":[null],"ro":false,"rm":false}]},
 {"name":"vde","path":"/dev/vde","type":"disk","size":107374182400,"fstype":"zfs_member","pttype":null,"label":"tank","uuid":"zfs-uuid","mountpoints":[null],"ro":false,"rm":false},
 {"name":"vdf","path":"/dev/vdf","type":"disk","size":536870912,"fstype":null,"pttype":null,"label":null,"uuid":null,"mountpoints":[null],"ro":false,"rm":false},
 {"name":"vdg","path":"/dev/vdg","type":"disk","size":107374182400,"fstype":null,"pttype":"dos","label":null,"uuid":null,"mountpoints":[null],"ro":false,"rm":false},
 {"name":"vdh","path":"/dev/vdh","type":"disk","size":107374182400,"fstype":null,"pttype":null,"label":null,"uuid":null,"mountpoints":[null],"ro":"1","rm":"0"},
 {"name":"vdi","path":"/dev/vdi","type":"disk","size":107374182400,"fstype":"ext4","pttype":null,"label":"data","uuid":"data-uuid","mountpoints":[null],"ro":false,"rm":false},
 {"name":"loop0","path":"/dev/loop0","type":"loop","size":107374182400,"fstype":null,"pttype":null,"label":null,"uuid":null,"mountpoints":[null],"ro":false,"rm":false}
]}
JSON
}

@test "disk_candidates: empty disks and unmounted filesystems only" {
    command -v jq >/dev/null || skip "needs jq"
    run disk_candidates "UUID=data-uuid" < <(lsblk_fixture)
    [ "$status" -eq 0 ]
    echo "$output"
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "fs	/dev/vda3	4000000000	ext4	spare" ]     # unmounted partition of the root disk
    [ "${lines[1]}" = "empty	/dev/vdb	274877906944		" ]
    [ "${lines[2]}" = "fs	/dev/vdc	107374182400	ext4	generated" ]
    # not: sr0 (CD-ROM), vda1/vda2/vda4 (mounted, swap), vdd (LVM), vde (ZFS), vdf (< 1 GiB),
    # vdg (a partition table), vdh (read-only, "1" as older lsblk prints it), vdi (in fstab), loop0
    run disk_candidates "" < <(lsblk_fixture)
    [[ "$output" == *"/dev/vdi"* ]]
    run disk_candidates $'LABEL=generated\n/dev/vda3' < <(lsblk_fixture)
    [[ "$output" != *"/dev/vdc"* && "$output" != *"/dev/vda3"* ]]
    run disk_candidates "PARTUUID=p-spare" < <(lsblk_fixture)
    [[ "$output" != *"/dev/vda3"* ]]
}

@test "disk_candidates_here: fstab's sources, quoted or not, are in use" {
    command -v jq >/dev/null || skip "needs jq"
    lsblk() { lsblk_fixture; }; wipefs() { :; }
    mkdir -p "$T/etc"; printf '# c\nUUID="spare-uuid" /x ext4 defaults 0 2\n' > "$T/etc/fstab"
    awk() { if [[ "$*" == *"/etc/fstab"* ]]; then command awk "${@:1:$#-1}" "$T/etc/fstab"; else command awk "$@"; fi; }
    run disk_candidates_here
    [[ "$output" != *"/dev/vda3"* && "$output" == *"/dev/vdb"* ]]
}

@test "uninstall's generated folder: under services/, never Docker's containerd/" {
    GEN_DIR=/opt/generated; generated_mounted() { return 0; }
    [ "$(generated_value /opt/homelab/services/containerd models)" = /opt/generated/services/containerd/models ]
    [ "$(generated_value /opt/homelab/services/immich ml-cache)" = /opt/generated/services/immich/ml-cache ]
}

@test "containerd drop-in: the unit's own command plus --root, and the mount required" {
    GEN_DIR=/opt/generated
    run containerd_dropin_text "/usr/bin/containerd --log-level warn"
    [[ "$output" == *$'\nRequiresMountsFor=/opt/generated\n'* ]]
    [[ "$output" == *$'\nExecStart=\nExecStart=/usr/bin/containerd --log-level warn --root /opt/generated/containerd'* ]]
    # RequiresMountsFor falls back to / without a mount unit: the start guard refuses then
    [[ "$output" == *"ExecStartPre=/bin/sh -c 'mountpoint -q /opt/generated || {"* ]]
    run docker_dropin_text
    [[ "$output" == *$'RequiresMountsFor=/opt/generated\n'* && "$output" == *"ExecStartPre=/bin/sh -c 'mountpoint -q /opt/generated"* ]]
    # the guard itself: fails on a plain folder, passes on a mount point
    GEN_DIR="$T/plain"; mkdir -p "$GEN_DIR"; g2=$(mount_guard); g2=${g2#ExecStartPre=}
    eval "run ${g2}"; [ "$status" -eq 1 ]
    [[ "$output" == *"is not mounted: refusing to start"* ]]
    GEN_DIR=/proc; g3=$(mount_guard); g3=${g3#ExecStartPre=}
    eval "run ${g3}"; [ "$status" -eq 0 ]
}

@test "st_generated_status: a VM's disk mounted but missing from /etc/fstab is todo" {
    GEN_DIR="$T/gen"; SETUP_VIRT=vm
    findmnt() { echo 64G; }; generated_mounted() { return 0; }
    generated_in_fstab() { return 1; }
    [ "$(st_generated_status)" = "todo: mounted, but not in /etc/fstab" ]
    generated_in_fstab() { return 0; }
    [ "$(st_generated_status)" = "done: 64G at $T/gen" ]
    SETUP_VIRT=lxc; generated_in_fstab() { return 1; }     # an LXC's mount point comes from the host
    [ "$(st_generated_status)" = "done: 64G at $T/gen" ]
}

@test "generated_in_fstab: the mount point with or without a trailing slash, comments ignored" {
    GEN_DIR=/opt/generated
    awk() { command awk "${@:1:$#-1}" "$T/fstab"; }
    printf '# /dev/x /opt/generated ext4\nUUID=a / ext4 defaults 0 1\n' > "$T/fstab"; ! generated_in_fstab || false
    printf 'LABEL=generated /opt/generated/ ext4 defaults 0 2\n' > "$T/fstab"; generated_in_fstab
    printf 'LABEL=generated /opt/generated ext4 defaults 0 2\n' > "$T/fstab"; generated_in_fstab
    printf 'LABEL=x /opt/generated-old ext4 defaults 0 2\n' > "$T/fstab"; ! generated_in_fstab || false
}

@test "setup steps: generated before docker, dockerstore after it" {
    s=" ${SETUP_STEPS[*]} "
    [[ "$s" == *" swap generated docker dockerstore dockerlogs "* ]]
    SETUP_VIRT=lxc; step_applies generated
    SETUP_VIRT=bare; ! step_applies generated || false
    SETUP_DOCKER=0; ! step_applies dockerstore || false
    SETUP_DOCKER=1; step_applies dockerstore
}

@test "st_generated_status: a mount point wins over an earlier 'no disk'" {
    GEN_DIR="$T/gen"; SETUP_VIRT=vm
    generated_mounted() { return 1; }
    [[ "$(st_generated_status)" == todo* ]]
    state_set generated none
    [ "$(st_generated_status)" = "done: none (answered: no disk)" ]
    findmnt() { echo 64G; }; generated_mounted() { return 0; }; generated_in_fstab() { return 0; }
    [ "$(st_generated_status)" = "done: 64G at $T/gen" ]
}

@test "alloy_token: asked when setting up (hidden, checked), a local monitoring too; --yes warns" {
    PUSH_TOKEN_FILE="$T/push-token"; tok=0123456789abcdef0123456789abcdef
    ALLOY_PROM=http://mon.example:9090; SETUP_PUSHTOKEN=""; SETUP_YES=0
    alloy_token <<< $'too-short\n'"$tok" >/dev/null
    [ "$SETUP_PUSHTOKEN" = "$tok" ]                               # a wrong one is asked again
    SETUP_PUSHTOKEN=""; out=$(alloy_token <<< '' 2>&1)            # Enter: none, with a warning
    [ -z "$SETUP_PUSHTOKEN" ]; [[ "$out" == *"no push token"* ]]
    echo "$tok" > "$PUSH_TOKEN_FILE"; out=$(alloy_token <<< '' 2>&1)   # Enter keeps the one there
    [ -z "$SETUP_PUSHTOKEN" ]; [[ "$out" != *"no push token"* ]]
    rm "$PUSH_TOKEN_FILE"; SETUP_YES=1; out=$(alloy_token 2>&1 </dev/null)   # --yes: never asks, warns
    [[ "$out" == *"no push token"* ]]
    SETUP_YES=0; ALLOY_PROM=http://localhost:9090; out=$(alloy_token 2>&1 </dev/null)   # its own monitoring: through the push-gate too
    [[ "$out" == *"no push token"* ]]
    SETUP_PUSHTOKEN=""; alloy_token <<< "$tok" >/dev/null; [ "$SETUP_PUSHTOKEN" = "$tok" ]
    SETUP_PUSHTOKEN="$tok"; ALLOY_PROM=http://mon.example:9090; out=$(alloy_token 2>&1 </dev/null)   # given by flag
    [ -z "$out" ]
}

@test "update: unticked where the kernel drives an NVIDIA GPU (not in an LXC); keeps the kernel's headers" {
    PCI_DEVICES="$T/pci"; mkdir -p "$T/pci/0000:01:00.0" "$T/bin"; d="$T/pci/0000:01:00.0"
    echo 0x1af4 > "$d/vendor"; echo 0x030000 > "$d/class"            # another vendor's display
    PATH="$T/bin:/usr/bin:/bin"
    SETUP_VIRT=vm; ! step_optional update || false; [ "$(st_update_status)" = todo ]
    echo 0x10de > "$d/vendor"; echo 0x040300 > "$d/class"            # NVIDIA, but its audio function
    ! step_optional update || false
    echo 0x030000 > "$d/class"                                       # NVIDIA display, no driver yet
    step_optional update; [[ "$(st_update_status)" == "todo: off by default (NVIDIA GPU"* ]]
    SETUP_VIRT=lxc; ! step_optional update || false; [ "$(st_update_status)" = todo ]   # the host's kernel, not its own
    rm -r "$T/pci"; mkdir "$T/pci"; printf '#!/bin/sh\n' > "$T/bin/nvidia-smi"; chmod +x "$T/bin/nvidia-smi"
    SETUP_VIRT=vm; step_optional update                              # the driver's tool alone
    # the run: the kernel's own headers package first, then the upgrade
    uname() { echo 6.12.117+deb13-amd64; }
    apt_get() { echo "apt-get $*" >> "$T/apt"; }
    dpkg() { return 1; }
    st_update_run
    [ "$(head -n 1 "$T/apt")" = "apt-get -y -q install linux-headers-amd64" ]
    grep -q full-upgrade "$T/apt"
    rm "$T/apt"; dpkg() { return 0; }; st_update_run                # already in: not installed again
    ! grep -q linux-headers "$T/apt" || false
    rm "$T/apt"; rm "$T/bin/nvidia-smi"; st_update_run              # no GPU: no headers
    ! grep -q linux-headers "$T/apt" || false
}

@test "step_optional: the no-backup disk is ticked only with something to do" {
    SETUP_VIRT=lxc; GEN_DIR="$T/gen"
    generated_mounted() { return 1; }
    step_optional generated; step_optional dockerstore             # no mount point: unticked, like fail2ban
    st_generated_status() { echo "todo: unused disk /dev/sdb"; }
    ! step_optional generated || false                               # a VM's unused disk: ticked
    generated_mounted() { return 0; }
    ! step_optional generated || false; ! step_optional dockerstore || false        # mounted: ticked (images to move)
    ! step_optional docker || false                               # the rest as before
}

@test "pushtoken step: todo without a token (a local monitoring too), done with one; run puts it in" {
    ALLOY_CFG="$T/config.alloy"; PUSH_TOKEN_FILE="$T/push-token"; tok=0123456789abcdef0123456789abcdef
    [[ " ${SETUP_STEPS[*]} " == *" alloy pushtoken "* ]]                      # right after Alloy
    [ "$(st_pushtoken_status)" = "todo: after Alloy" ]                          # no Alloy yet
    printf 'url = "http://mon.example:9090/api/v1/write"\nurl = "http://mon.example:3100/loki/api/v1/push"\n' > "$ALLOY_CFG"
    [[ "$(st_pushtoken_status)" == "todo: none yet"* ]]
    [ "$(alloy_cfg_url /api/v1/write)" = http://mon.example:9090 ]
    [ "$(alloy_cfg_url /loki/api/v1/push)" = http://mon.example:3100 ]
    # run: asked (a bad one again), then Alloy's config redone with the same URLs and the token
    st_alloy_run() { echo "$SETUP_PROM $SETUP_LOKI $SETUP_PUSHTOKEN" > "$T/ran"; echo "$SETUP_PUSHTOKEN" > "$PUSH_TOKEN_FILE"
                     printf '  bearer_token_file = "x"\n  bearer_token_file = "x"\n' >> "$ALLOY_CFG"; }
    SETUP_YES=0; SETUP_PUSHTOKEN=""; SETUP_PROM=""; SETUP_LOKI=""
    st_pushtoken_run <<< $'short\n'"$tok" >/dev/null
    [ "$(cat "$T/ran")" = "http://mon.example:9090 http://mon.example:3100 $tok" ]
    [ -z "$SETUP_PROM" ]                                                        # its own answers untouched
    [ "$(st_pushtoken_status)" = done ]
    # Enter with none there: nothing changes, stays todo
    rm "$T/ran" "$PUSH_TOKEN_FILE"; printf 'url = "http://mon.example:9090/api/v1/write"\nurl = "http://mon.example:3100/loki/api/v1/push"\n' > "$ALLOY_CFG"
    SETUP_PUSHTOKEN=""; st_pushtoken_run <<< '' >/dev/null
    [ ! -e "$T/ran" ]; [[ "$(st_pushtoken_status)" == "todo: none yet"* ]]
    # --yes: never asks
    SETUP_YES=1; st_pushtoken_run </dev/null >/dev/null; [ ! -e "$T/ran" ]
    # a monitoring on this machine: its Alloy pushes through the push-gate too, so the same
    printf 'url = "http://localhost:9090/api/v1/write"\nurl = "http://localhost:3100/loki/api/v1/push"\n' > "$ALLOY_CFG"
    [[ "$(st_pushtoken_status)" == "todo: none yet"* ]]
    SETUP_YES=0; SETUP_PUSHTOKEN=""; st_pushtoken_run <<< "$tok" >/dev/null
    [ "$(cat "$T/ran")" = "http://localhost:9090 http://localhost:3100 $tok" ]
    [ "$(st_pushtoken_status)" = done ]
}

# ── consistency: help, dispatch, setup flags and steps agree ───────────────────

@test "every command in labber help is dispatched" {
    local help cmds main c missing=""
    # the "Commands:" section only, up to the next blank line
    help=$(usage 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/^Commands:/,/^$/p')
    # "  [svc] install …", "  setup …", "  ls -r|--remote …": the first word of each command line
    cmds=$(sed -nE 's/^  (\[svc\] )?([a-z][a-z-]+)( .*|$)/\2/p' <<< "$help" | sort -u)
    [ "$(wc -l <<< "$cmds")" -ge 15 ]                                       # the parse found the list
    main=$(declare -f labber_main)
    for c in $cmds; do
        grep -qE "(^|[[:space:]|(\"])${c}(\||\)|\"|[[:space:]]+\)?)" <<< "$main" || missing+=" $c"
    done
    [ -z "$missing" ] || { echo "in help, not dispatched:$missing"; false; }
}

@test "setup: every flag in its usage is parsed, and every parsed flag is in its usage and in help" {
    local parsed usage help f missing=""
    # the parser's case labels only (not flags named in its messages): "--yes | -y)", "--with | --without)"
    parsed=$(declare -f setup_args | grep -E '^\s*--[a-z][a-z-]*( *\| *-[-a-z]+)* *\)' | grep -oE -- '--[a-z][a-z-]+' | sort -u)
    usage=$(grep -oE -- '--[a-z][a-z-]+' <<< "$SETUP_USAGE" | sort -u)
    help=$(usage 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/^  setup /,/^  disks /p' | grep -oE -- '--[a-z][a-z-]+' | sort -u)
    for f in $usage; do grep -qx -- "$f" <<< "$parsed" || missing+=" usage-not-parsed:$f"; done
    for f in $parsed; do
        [[ "$f" == --without || "$f" == --dry-run ]] && continue           # parsed together with --with / -n
        grep -qx -- "$f" <<< "$usage" || missing+=" parsed-not-in-usage:$f"
        grep -qx -- "$f" <<< "$help"  || missing+=" parsed-not-in-help:$f"
    done
    [ -z "$missing" ] || { echo "$missing"; false; }
}

@test "every setup step has a title, a status and a run, and appears once" {
    local id bad=""
    [ "$(printf '%s\n' "${SETUP_STEPS[@]}" | sort | uniq -d)" = "" ]
    for id in "${SETUP_STEPS[@]}"; do
        [ -n "$(step_title "$id")" ] || bad+=" $id:no-title"
        declare -F "st_${id}_status" >/dev/null || bad+=" $id:no-status"
        declare -F "st_${id}_run" >/dev/null || bad+=" $id:no-run"
    done
    [ -z "$bad" ] || { echo "$bad"; false; }
}

@test "push-tokens.sh reads labber's step list: every step but alloy" {
    local script="$BATS_TEST_DIRNAME/../../services/monitoring/utils/push-tokens.sh" others want
    [ -f "$script" ] || skip "no push-tokens.sh"
    # the same sed the script runs inside a guest, on this labber
    others=$(sed -n "s/^SETUP_STEPS=(\(.*\)).*/\1/p" "$LABBER" | head -n 1 | tr " " "\n" | grep -vx alloy | paste -sd, -)
    want=$(printf '%s\n' "${SETUP_STEPS[@]}" | grep -vx alloy | paste -sd, -)
    [ "$others" = "$want" ]
    grep -qF 'sed -n "s/^SETUP_STEPS=(\(.*\)).*/\1/p"' "$script"         # and the script still uses it
}
