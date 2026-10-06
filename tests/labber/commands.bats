#!/usr/bin/env bats
# Integration tests for the rest of labber's commands (the ones integration.bats doesn't
# cover): restart, logs, shell, go, reinstall, deploy, self-install/self-update,
# completion, tool, the menu, uninstall-keeping-the-folder and clean.
# Run ON the test VM by run-vm.sh, after integration.bats. Same environment variables.
#
# Note: this replaces /usr/local/bin/labber on the VM with the labber under test, and
# `clean` prunes ALL unused Docker data on the VM — throwaway VMs only.

SVC=labber-test

setup_file() {
    export SVC_DIR="$LABBER_SERVICE_BASE/$SVC"
    if [ -d "$SVC_DIR" ]; then (cd "$SVC_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true; fi
    sudo -n rm -rf "$LABBER_SERVICE_BASE"
    mkdir -p "$LABBER_SERVICE_BASE"
    # fresh install to work with (answers: generate secrets · api_token · web_host · web_port · Enter when ready)
    script -qefc "bash $LABBER $SVC install" /dev/null <<< $'\nfixture-token\n\n\n\n' >/dev/null
}

teardown_file() {
    if [ -d "$SVC_DIR" ]; then (cd "$SVC_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true; fi
    docker image rm labber-test-job >/dev/null 2>&1 || true
    sudo -n rm -rf "$LABBER_SERVICE_BASE"
    # leave the VM with the labber under test installed (not the bumped test copy)
    sudo -n install -m 755 "$LABBER" /usr/local/bin/labber
}

tty_run() {
    local input="$1"; shift
    local cmd; printf -v cmd '%q ' "$@"
    run script -qefc "$cmd" /dev/null <<< "$input"
    output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
}

lbr() { run bash "$LABBER" "$@" < /dev/null; }
web_id() { docker inspect -f '{{.Id}}' "$SVC-web-1" 2>/dev/null; }

# ── per-service commands ──────────────────────────────────────────────────────

@test "status lists the service's containers" {
    lbr "$SVC" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SVC-web-1"* ]]
}

@test "restart recreates the containers" {
    before=$(web_id)
    lbr "$SVC" restart
    [ "$status" -eq 0 ]
    after=$(web_id)
    [ -n "$after" ] && [ "$after" != "$before" ]
}

@test "logs follows the service's logs" {
    run timeout 5 bash "$LABBER" "$SVC" logs < /dev/null
    [ "$status" -eq 124 ]    # still following when the timeout stopped it
}

@test "shell opens sh when the container has no bash" {
    tty_run $'echo inside-$((6*7))\nexit\n' bash "$LABBER" "$SVC" shell
    echo "$output"
    [[ "$output" == *"inside-42"* ]]
}

@test "reinstall over an existing install keeps .env and stays up" {
    secret=$(grep '^SECRET=' "$SVC_DIR/.env")
    tty_run $'y\n' bash "$LABBER" "$SVC" install
    echo "$output"
    [[ "$output" == *"already installed"* ]]
    [ "$(grep '^SECRET=' "$SVC_DIR/.env")" = "$secret" ]
    [ "$(docker inspect -f '{{.State.Running}}' "$SVC-web-1")" = true ]
}

@test "deploy is an alias for install (answering no aborts)" {
    tty_run $'n\n' bash "$LABBER" "$SVC" deploy
    [[ "$output" == *"already installed"* ]]
    [[ "$output" == *"aborted"* ]]
}

@test "deploy without a service offers the repo's services to pick from" {
    repo="${LABBER_REPO#file://}"
    n=$(find "$repo/services" -maxdepth 3 -name docker-compose.yml -exec dirname {} \; \
        | sed "s|^$repo/services/||" | sort | grep -nx "$SVC" | cut -d: -f1)
    [ -n "$n" ]
    tty_run "$n"$'\nn\n' bash "$LABBER" deploy
    echo "$output"
    [[ "$output" == *"Select service to install"* ]]
    [[ "$output" == *"'$SVC' already installed"* ]]
}

@test "update for a service that isn't in the repo fails clearly" {
    mkdir -p "$LABBER_SERVICE_BASE/not-in-repo"
    printf 'services: {}\n' > "$LABBER_SERVICE_BASE/not-in-repo/docker-compose.yml"
    lbr not-in-repo update
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found in repo"* ]]
    rm -rf "$LABBER_SERVICE_BASE/not-in-repo"
}

# ── labber itself ─────────────────────────────────────────────────────────────

@test "install: puts labber in /usr/local/bin with shell function and completion" {
    # answers: overwrite the existing labber? · enable tab completion?
    tty_run $'y\ny\n' bash "$LABBER" install
    echo "$output"
    cmp -s "$LABBER" /usr/local/bin/labber
    [ "$(stat -c '%U %a' /usr/local/bin/labber)" = "root 755" ]
    [ ! -e /usr/local/bin/labber.new ]
    [ "$(grep -cx '# labber shell function' ~/.bashrc)" -eq 1 ]
    [ "$(grep -cx '# labber completion' ~/.bashrc)" -eq 1 ]
}

@test "go: the shell function changes into the service folder" {
    run bash -ic "labber $SVC go && pwd" < /dev/null
    [ "${lines[-1]}" = "$SVC_DIR" ]
}

@test "completion offers global commands" {
    run bash -ic 'COMP_WORDS=(labber che); COMP_CWORD=1; _labber_complete; echo "${COMPREPLY[*]}"' < /dev/null
    [[ "${lines[-1]}" == *check-updates* ]]
    run bash -ic 'COMP_WORDS=(labber some-svc re); COMP_CWORD=2; _labber_complete; echo "${COMPREPLY[*]}"' < /dev/null
    [[ "${lines[-1]}" == *restart* && "${lines[-1]}" == *rebuild* ]]
}

@test "update: self-updates when the published version is newer, not when it's the same" {
    newer="$BATS_FILE_TMPDIR/labber-newer"
    sed -E 's/^VERSION="[^"]*"/VERSION="99.0.0"/' "$LABBER" > "$newer"
    run env LABBER_URL="file://$newer" bash /usr/local/bin/labber update < /dev/null
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"labber updated"*"v99.0.0"* ]]
    grep -qx 'VERSION="99.0.0"' /usr/local/bin/labber
    run env LABBER_URL="file://$newer" bash /usr/local/bin/labber update < /dev/null
    [[ "$output" == *"already on latest (v99.0.0)"* ]]
    sudo -n install -m 755 "$LABBER" /usr/local/bin/labber
}

@test "tool ls lists the repo's tools" {
    lbr tool ls
    [ "$status" -eq 0 ]
    [[ "$output" == *fzf* ]]
}

@test "tool fzf runs the repo's install script" {
    lbr tool fzf
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fzf installed"* ]]
    [ -x ~/.fzf/bin/fzf ]
}

@test "menu shows services and commands, q quits" {
    tty_run $'q\n' bash "$LABBER"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed services:"* ]]
    [[ "$output" == *"$SVC"* ]]
    [[ "$output" == *"commands:"* ]]
}

# ── uninstall keeping the folder, clean ───────────────────────────────────────

@test "uninstall can keep the service folder" {
    # answers: remove containers + images? yes · delete the folder? no
    tty_run $'y\nn\n' bash "$LABBER" "$SVC" uninstall
    echo "$output"
    [ -d "$SVC_DIR" ]
    [ -f "$SVC_DIR/.env" ]
    [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$SVC")" ]
    [[ "$output" == *"service directory kept"* ]]
    # keeping the folder keeps the data: named volumes stay too
    [ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$SVC")" ]
    docker volume ls -q --filter "label=com.docker.compose.project=$SVC" | xargs -r docker volume rm >/dev/null
}

@test "clean: answering no changes nothing" {
    tty_run $'n\n' bash "$LABBER" clean
    [[ "$output" == *aborted* ]]
}

@test "clean: prunes unused Docker data" {
    docker create --name labber-test-unused busybox:1.37 >/dev/null
    tty_run $'y\n' bash "$LABBER" clean
    echo "$output"
    [[ "$output" == *"docker cleaned"* ]]
    ! docker inspect labber-test-unused >/dev/null 2>&1
}
