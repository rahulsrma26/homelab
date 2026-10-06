#!/usr/bin/env bats
# Integration tests for labber against real Docker, run ON the test VM by run-vm.sh.
# Tests run in order and build on each other (install → ls → … → uninstall).
#
# Expects (set by run-vm.sh):
#   LABBER               path to the labber under test
#   LABBER_REPO          file:// URL of a git snapshot of the working tree (+ labber-test fixture)
#   LABBER_URL           file:// URL of the labber under test (for self-install)
#   LABBER_SERVICE_BASE  a scratch services folder, so real services are never touched
#   passwordless sudo for the test user (setup and root-owned data cleanup need it)

SVC=labber-test
PORT=18765

setup_file() {
    export SVC_DIR="$LABBER_SERVICE_BASE/$SVC"
    docker rm -f labber-test-conflict >/dev/null 2>&1 || true
    if [ -d "$SVC_DIR" ]; then (cd "$SVC_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true; fi
    sudo -n rm -rf "$LABBER_SERVICE_BASE"
    mkdir -p "$LABBER_SERVICE_BASE"
}

teardown_file() {
    docker rm -f labber-test-conflict >/dev/null 2>&1 || true
    if [ -d "$SVC_DIR" ]; then (cd "$SVC_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true; fi
    docker image rm labber-test-job >/dev/null 2>&1 || true
    sudo -n rm -rf "$LABBER_SERVICE_BASE"
}

# run labber in a pseudo-terminal (it only prompts when someone is at a keyboard),
# feeding the answers in $1
tty_run() {
    local input="$1"; shift
    local cmd; printf -v cmd '%q ' "$@"
    run script -qefc "$cmd" /dev/null <<< "$input"
    output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
}

lbr() { run bash "$LABBER" "$@" < /dev/null; }

# the port-conflict test starts this; make sure a failure there can't leak into later tests
teardown() { docker rm -f labber-test-conflict >/dev/null 2>&1 || true; }

web_running() { [ "$(docker inspect -f '{{.State.Running}}' "$SVC-web-1" 2>/dev/null)" = true ]; }

@test "install: generates secrets, takes typed values, starts the service" {
    # answers: generate secret + password? (Enter = yes) · api_token · web_host (Enter =
    # default, asked once though used twice) · web_port (default) · "Press Enter when ready"
    tty_run $'\nfixture-token\n\n\n\n' bash "$LABBER" "$SVC" install
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(grep '^SECRET=' "$SVC_DIR/.env")" =~ ^SECRET=[a-f0-9]{64}$ ]]
    [[ "$(grep '^PASSWORD=' "$SVC_DIR/.env")" =~ ^PASSWORD=[A-Za-z0-9]{16}\ +#\ generated\ on\ install$ ]]
    grep -qx 'API_TOKEN=fixture-token' "$SVC_DIR/.env"
    grep -qx 'WEB_URL=http://localhost:18765/' "$SVC_DIR/.env"
    grep -qx 'WEB_HOST=localhost' "$SVC_DIR/.env"
    [ "$(grep -c 'web_host \[localhost\]' <<< "$output")" -eq 1 ]     # asked once
    web_running
}

@test "install: data folder created with PUID/PGID owner, port answers" {
    [ "$(stat -c %u:%g "$SVC_DIR/data/www")" = "1234:1234" ]
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
    [ "$code" = 404 ]   # busybox httpd with an empty folder: reachable, nothing to serve
}

@test "ls: service up with its port; the finished one-shot job isn't counted as down" {
    lbr ls
    echo "$output"
    line=$(grep "$SVC" <<< "$output")
    [[ "$line" == *"1/1 up"* ]]
    [[ "$line" == *":$PORT"* ]]
}

@test "labber <svc> alone shows status and commands" {
    lbr "$SVC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"commands:"* ]]
}

@test "stop, then ls shows stopped, then start brings it back" {
    lbr "$SVC" stop
    ! web_running
    lbr ls
    [[ "$(grep "$SVC" <<< "$output")" == *stopped* ]]
    lbr "$SVC" start
    [ "$status" -eq 0 ]
    web_running
}

@test "start refuses a port already used by another container" {
    lbr "$SVC" stop
    docker run -d --name labber-test-conflict -p "$PORT:80" busybox:1.37 httpd -f -p 80 >/dev/null
    lbr "$SVC" start
    echo "$output"
    [[ "$output" == *"port conflict"* ]]
    [[ "$output" == *"container labber-test-conflict"* ]]
    ! web_running
    docker rm -f labber-test-conflict >/dev/null
    lbr "$SVC" start
    web_running
}

@test "start refuses while a value in .env is still unset (no terminal)" {
    lbr "$SVC" stop
    cp -p "$SVC_DIR/.env" "$BATS_FILE_TMPDIR/env.bak"
    sed -i 's/^API_TOKEN=.*/API_TOKEN={{ api_token }}/' "$SVC_DIR/.env"
    lbr "$SVC" start
    echo "$output"
    [[ "$output" == *"still unset"*"API_TOKEN"* ]]
    ! web_running
    cp -p "$BATS_FILE_TMPDIR/env.bak" "$SVC_DIR/.env"
    lbr "$SVC" start
    web_running
}

@test "rebuild: skips pulling the local image, builds it, service stays up" {
    lbr "$SVC" rebuild
    echo "$output"
    [ "$status" -eq 0 ]
    docker image inspect labber-test-job >/dev/null
    web_running
}

@test "check-updates: flags a repo change for the service" {
    repo="${LABBER_REPO#file://}"
    echo 'NEW_SETTING=hello' >> "$repo/services/$SVC/.env.example"
    git -C "$repo" -c user.name=labber-test -c user.email=labber-test@localhost commit -qam "fixture: add NEW_SETTING"
    lbr check-updates
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(grep "$SVC" <<< "$output")" == *"repo config changed"* ]]
    lbr ls
    [[ "$(grep "$SVC" <<< "$output")" == *"repo config changed"* ]]
}

@test "update: new files and .env keys arrive, existing .env values stay" {
    secret_before=$(grep '^SECRET=' "$SVC_DIR/.env")
    lbr "$SVC" update
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'NEW_SETTING=hello' "$SVC_DIR/.env"
    [ "$(grep '^SECRET=' "$SVC_DIR/.env")" = "$secret_before" ]
    grep -qx 'API_TOKEN=fixture-token' "$SVC_DIR/.env"
    [ ! -e "$SVC_DIR/.env.labber-bak" ]
    web_running
    lbr ls
    [[ "$(grep "$SVC" <<< "$output")" != *"repo config changed"* ]]
}

@test "uninstall: removes containers, local image and folder (incl. root-owned data)" {
    docker exec "$SVC-web-1" touch /www/created-by-root
    [ "$(stat -c %U "$SVC_DIR/data/www/created-by-root")" = root ]
    # answers: remove containers + images? · delete the folder?
    tty_run $'y\ny\n' bash "$LABBER" "$SVC" uninstall
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -d "$SVC_DIR" ]
    [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$SVC")" ]
    ! docker image inspect labber-test-job >/dev/null 2>&1
    [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$SVC")" ]
}

@test "setup: re-run on an already set-up VM has nothing left to do" {
    sudo -n true || skip "needs passwordless sudo"
    [ -f /etc/ssh/sshd_config.d/10-labber.conf ] || skip "VM hasn't been through labber setup"
    # answers: Docker services? (Enter keeps the last answer: yes) · quit the checklist
    tty_run $'\nq\n' sudo -n bash "$LABBER" setup
    echo "$output"
    [[ "$output" == *"nothing changed"* ]]
    [[ "$output" == *"Will this machine run Docker services?"* ]]
    [[ "$output" == *"Docker (official repo)"* ]]
    # every step that isn't always-offered (update) or optional (nfs, fail2ban) is done
    todo=$(grep -E '^ +[0-9]+ \[' <<< "$output" | grep -v -E 'system update|NFS|fail2ban' | grep -c ' todo' || true)
    [ "$todo" -eq 0 ]
}

@test "setup: optional steps and the network step can be picked on a later run" {
    sudo -n true || skip "needs passwordless sudo"
    [ -f /etc/ssh/sshd_config.d/10-labber.conf ] || skip "VM hasn't been through labber setup"
    # step numbers come from the checklist itself, so this works whatever the order
    tty_run $'\nq\n' sudo -n bash "$LABBER" setup
    num() { grep -E "^ +[0-9]+ \[.\] $1" <<< "$output" | awk '{print $1}'; }
    update=$(num 'system update'); nfs=$(num 'NFS client'); f2b=$(num 'fail2ban'); net=$(num 'network:')
    [ -n "$update" ] && [ -n "$nfs" ] && [ -n "$f2b" ] && [ -n "$net" ]
    # answers: Docker? Enter · untick update, tick NFS + fail2ban + network · run · network: 3 = skip
    tty_run $'\n'"$update $nfs $f2b $net"$'\n\n3\n' sudo -n bash "$LABBER" setup
    echo "$output"
    [[ "$output" == *"done: nfs fail2ban network"* ]]
    [[ "$output" == *"network unchanged"* ]]
    dpkg-query -W -f='${Status}' nfs-common | grep -q 'install ok installed'
    systemctl is-active --quiet fail2ban
    sudo -n fail2ban-client status sshd >/dev/null
    # next run: both now show as done
    tty_run $'\nq\n' sudo -n bash "$LABBER" setup
    [[ "$(grep -E 'NFS client' <<< "$output")" == *done* ]]
    [[ "$(grep -E 'fail2ban' <<< "$output")" == *done* ]]
}

@test "setup extras: Alloy runs with a valid config and exports the health metrics" {
    systemctl is-active --quiet alloy || skip "Alloy not set up on this VM"
    sudo -n alloy fmt /etc/alloy/config.alloy >/dev/null
    metrics=$(curl -s localhost:12345/api/v0/component/prometheus.exporter.unix.local/metrics)
    grep -q '^labber_reboot_required ' <<< "$metrics"
    grep -q '^labber_security_updates_pending ' <<< "$metrics"
    grep -q '^node_systemd_unit_state' <<< "$metrics"
}

@test "setup extras: zsh is the login shell, with labber and fzf set up in it" {
    [[ "$(getent passwd "$USER" | cut -d: -f7)" == */zsh ]] || skip "zsh not set up for $USER"
    [ "$(head -1 ~/.zshrc)" = "# labber zsh" ]          # must stay first (p10k instant prompt)
    grep -qx '# labber shell function' ~/.zshrc
    grep -qx '# labber completion' ~/.zshrc
    grep -q 'fzf' ~/.zshrc
    run zsh -ic 'whence -w labber _labber_complete' < /dev/null
    [[ "$output" == *"labber: function"* && "$output" == *"_labber_complete: function"* ]]
}
