#!/usr/bin/env bats
# Regression tests for the repository audit. Runs in the unit-test container.

setup() {
    LABBER="$BATS_TEST_DIRNAME/../../labber/labber"
    source "$LABBER"
    set +u
    T="$BATS_TEST_TMPDIR"
    cd "$T"
    LABBER_STATE_DIR="$T/state"
    HEALTH_SETTLE=0 HEALTH_TIMEOUT=0
    mkdir svc
    printf 'services:\n  web:\n    image: test-web\n' > svc/docker-compose.yml
}

mock_docker() {
    TRACE="$T/docker.trace"
    FAIL_STAGE="" HEALTH_MODE=ok BUILD_ENABLED=0
    ACTIVE_SERVICES=$'web\njob'
    RESOLVED_CONFIG='{"services":{"web":{"depends_on":{"job":{"condition":"service_completed_successfully"}}},"job":{}}}'
    WEB_STATE=running WEB_CODE=0 JOB_STATE=exited JOB_CODE=0
    docker() {
        printf '%s\n' "$*" >> "$TRACE"
        case "$*" in
            'compose pull --help') echo --ignore-buildable ;;
            'compose config --services')
                [[ "$FAIL_STAGE" != services ]] || return 7
                printf '%s\n' "$ACTIVE_SERVICES" ;;
            'compose config --format json')
                [[ "$FAIL_STAGE" != config ]] || return 7
                printf '%s\n' "$RESOLVED_CONFIG" ;;
            'compose config')
                cat "$T/svc/docker-compose.yml"
                if [[ "$BUILD_ENABLED" == 1 ]]; then echo '    build: .'; fi ;;
            'compose ps -aq')
                [[ "$FAIL_STAGE" != ps ]] || return 8
                [[ "$HEALTH_MODE" != empty ]] || return 0
                echo web-id
                if [[ "$HEALTH_MODE" != partial ]]; then echo job-id; fi ;;
            'compose pull --ignore-buildable') [[ "$FAIL_STAGE" != pull ]] ;;
            'compose build --pull') [[ "$FAIL_STAGE" != build ]] ;;
            'compose down --remove-orphans') [[ "$FAIL_STAGE" != down ]] ;;
            'compose up -d') [[ "$FAIL_STAGE" != up ]] ;;
            inspect*)
                [[ "$FAIL_STAGE" != inspect ]] || return 9
                if [[ "$3" == *'.Config.Image'* ]]; then
                    printf 'test-web\tsha256:previous\n'
                elif [[ "$4" == web-id ]]; then
                    printf '/web|%s|healthy|%s|0|2000-01-01T00:00:00Z|web\n' "$WEB_STATE" "$WEB_CODE"
                else
                    printf '/job|%s||%s|0|2000-01-01T00:00:00Z|job\n' "$JOB_STATE" "$JOB_CODE"
                fi ;;
            tag*) [[ "$FAIL_STAGE" != pin ]] ;;
        esac
    }
}

@test "failed pull or build keeps containers running and restores update files" {
    mock_docker
    BUILD_ENABLED=1
    mkdir old; cp svc/docker-compose.yml old/
    record_base old svc
    for stage in pull build; do
        bak=$(backup_svc_files old svc)
        printf 'changed\n' > svc/docker-compose.yml
        FAIL_STAGE="$stage"
        : > "$TRACE"
        run compose_refresh "$T/svc" "$bak"
        [ "$status" -eq 1 ]
        ! grep -q 'compose down\|compose up' "$TRACE"
        cmp old/docker-compose.yml svc/docker-compose.yml
        rm -rf "$bak"
    done
}

@test "image snapshot and pin failures stop refresh before pulling" {
    mock_docker
    for stage in ps inspect pin; do
        mkdir -p original
        cp svc/docker-compose.yml original/
        bak=$(backup_svc_files original svc)
        printf changed > svc/docker-compose.yml
        FAIL_STAGE="$stage"; : > "$TRACE"
        run compose_refresh "$T/svc" "$bak"
        [ "$status" -eq 1 ]
        ! grep -q 'compose pull\|compose down\|compose up' "$TRACE"
        cmp original/docker-compose.yml svc/docker-compose.yml
        rm -rf "$bak"
    done
}

@test "down and up failures are reported without a false healthy result" {
    mock_docker
    for stage in down up; do
        FAIL_STAGE="$stage"; : > "$TRACE"
        run compose_refresh "$T/svc"
        [ "$status" -eq 1 ]
        ! grep -q 'image prune' "$TRACE"
        if [[ "$stage" == down ]]; then ! grep -q 'compose up' "$TRACE"; fi
    done
}

@test "health rejects zero or missing containers and Docker inspection errors" {
    mock_docker
    for mode in empty partial; do
        HEALTH_MODE="$mode"
        run wait_healthy "$T/svc"
        [ "$status" -eq 1 ]
        if [[ "$mode" == partial ]]; then [[ "$output" == *'job has no container'* ]]; fi
    done
    HEALTH_MODE=ok
    for stage in ps inspect; do
        FAIL_STAGE="$stage"
        run wait_healthy "$T/svc"
        [ "$status" -eq 1 ]
    done
}

@test "health accepts a healthy service and a successful one-shot job" {
    mock_docker
    run wait_healthy "$T/svc"
    [ "$status" -eq 0 ]
    run compose_refresh "$T/svc"
    [ "$status" -eq 0 ]
    grep -q 'image prune' "$TRACE"
}

@test "health rejects clean exits from applications, including restart-no services" {
    mock_docker
    RESOLVED_CONFIG='{"services":{"web":{"restart":"no","depends_on":{"job":{"condition":"service_completed_successfully"}}},"job":{}}}'
    WEB_STATE=exited
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'web stopped with exit code 0'* ]]
}

@test "health waits for running jobs and rejects nonzero or dead jobs" {
    mock_docker
    JOB_STATE=running
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'job: not up after'* ]]
    JOB_STATE=exited JOB_CODE=5
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'job exited with code 5'* ]]
    JOB_STATE=dead JOB_CODE=0
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'job is dead'* ]]
    WEB_STATE=dead JOB_STATE=exited
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'web is dead'* ]]
}

@test "health only accepts jobs declared by completion dependencies" {
    mock_docker
    # An override can change a dependency back to an ordinary running service.
    # Labels and command strings containing the condition must not classify jobs.
    RESOLVED_CONFIG='{"services":{"web":{"depends_on":{"job":{"condition":"service_started"}}},"job":{"labels":{"note":"service_completed_successfully"}}}}'
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'job stopped with exit code 0'* ]]
    RESOLVED_CONFIG='{"services":{"web":{},"job":{}}}'
    run wait_healthy "$T/svc"
    [ "$status" -eq 1 ]
    [[ "$output" == *'job stopped with exit code 0'* ]]
}

@test "health ignores inactive services and orphan jobs when no jobs are declared" {
    mock_docker
    ACTIVE_SERVICES=web
    RESOLVED_CONFIG='{"services":{"web":{},"optional":{"profiles":["extra"]}}}'
    run wait_healthy "$T/svc"
    [ "$status" -eq 0 ]
}

@test "health fails closed when resolved Compose job declarations cannot be read" {
    mock_docker
    for stage in services config; do
        FAIL_STAGE="$stage"
        run wait_healthy "$T/svc"
        [ "$status" -eq 1 ]
    done
    FAIL_STAGE=""
    for RESOLVED_CONFIG in 'not json' '' null '{}'; do
        run wait_healthy "$T/svc"
        [ "$status" -eq 1 ]
        [[ "$output" == *'could not identify Compose one-shot jobs'* ]]
    done
}

@test "overview counts stopped applications but excludes declared completed jobs" {
    SERVICE_BASE="$T/services"; mkdir -p "$SERVICE_BASE/example"
    cp svc/docker-compose.yml "$SERVICE_BASE/example/"
    docker() {
        case "$*" in
            'compose config --format json')
                printf '%s\n' '{"services":{"web":{"depends_on":{"job":{"condition":"service_completed_successfully"}}},"db":{},"job":{}}}' ;;
            'compose ps -a --format '*)
                printf 'web|exited||0|\ndb|running|healthy|0|\njob|exited||0|\n' ;;
        esac
    }
    run show_overview
    [ "$status" -eq 0 ]
    [[ "$output" == *'1/2 up'* ]]
}

@test "updates detect deletions, preserve edits and data, and roll deletions back" {
    mkdir old new
    printf old > old/removed.yml
    printf old > old/edited.yml
    cp svc/docker-compose.yml old/
    cp -r old/. svc/
    record_base old svc
    cp old/docker-compose.yml new/
    printf new > new/added.yml
    printf mine > svc/edited.yml
    printf data > svc/local-data
    printf 'SECRET=mine\n' > svc/.env
    [ "$(config_update_status new svc)" = yes ]
    bak=$(backup_svc_files new svc)
    run copy_svc_files new svc
    [ "$status" -eq 0 ]
    [[ "$output" == *'kept edited.yml'* ]]
    [ ! -e svc/removed.yml ]
    [ "$(cat svc/edited.yml)" = mine ]
    [ "$(cat svc/local-data)" = data ]
    [ "$(config_update_status new svc)" = yes ] # retained edited deletion remains visible
    restore_svc_files "$bak" svc
    [ "$(cat svc/removed.yml)" = old ]
    [ "$(cat svc/edited.yml)" = mine ]
    [ ! -e svc/added.yml ]
    [ "$(env_get svc/.env SECRET)" = mine ]
    rm -rf "$bak"
}

@test "deletion handling never removes unrelated or redirected data" {
    mkdir old new outside
    printf old > old/retired
    cp old/retired svc/
    record_base old svc
    mv svc/retired outside/retired
    ln -s "$T/outside/retired" svc/retired
    copy_svc_files new svc
    [ "$(cat outside/retired)" = old ]
    [ -L svc/retired ]
}

@test "root updates preserve manifest ownership and readability for daily checks" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    mkdir upstream
    cp svc/docker-compose.yml upstream/
    chown 65534:65534 svc
    record_base upstream svc
    [ "$(stat -c '%u:%g:%a' svc/.labber-base)" = 65534:65534:644 ]
    record_base upstream svc
    [ "$(stat -c '%u:%g:%a' svc/.labber-base)" = 65534:65534:644 ]
}

@test "root rollback preserves service and configuration directory ownership" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    mkdir -p upstream/config svc/config
    echo original > upstream/config/app.yml
    cp upstream/config/app.yml svc/config/
    chown -R 65534:65534 svc
    chmod 750 svc/config
    record_base upstream svc
    bak=$(backup_svc_files upstream svc)
    echo changed > svc/config/app.yml
    restore_svc_files "$bak" svc
    [ "$(cat svc/config/app.yml)" = original ]
    [ "$(stat -c '%u:%g' svc)" = 65534:65534 ]
    [ "$(stat -c '%u:%g:%a' svc/config)" = 65534:65534:750 ]
    rm -rf "$bak"
}

@test "new and existing env files are private including old backups" {
    printf 'TOKEN={{ token }}\n' > svc/.env.example
    sync_env_keys svc
    [ "$(stat -c %a svc/.env)" = 600 ]
    cp svc/.env svc/.env.labber-bak
    chmod 644 svc/.env svc/.env.labber-bak
    protect_env svc
    [ "$(stat -c %a svc/.env)" = 600 ]
    [ "$(stat -c %a svc/.env.labber-bak)" = 600 ]
}

@test "root-owned env mounted into a non-root container has narrow readable access" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    printf 'UID=65534\nGID=65534\nTOKEN=fixture\n' > svc/.env
    cfg=$(printf '    volumes:\n      - type: bind\n        source: %s/svc/.env\n        target: /app/.env\n' "$T")
    protect_env svc "$cfg"
    [ "$(stat -c '%u:%g:%a' svc/.env)" = 0:65534:640 ]
    # Parent access is opened only in this temporary fixture.
    chmod o+x "$BATS_RUN_TMPDIR" "$BATS_FILE_TMPDIR" "$T" svc 2>/dev/null || true
    run setpriv --reuid=65534 --regid=65534 --clear-groups cat "$T/svc/.env"
    [ "$status" -eq 0 ]
    [[ "$output" == *TOKEN=fixture* ]]
}

@test "netplan rollback restores an existing file or removes a newly introduced file" {
    mkdir netplan
    netplan() { :; }; setsid() { :; }
    eval "$(declare -f setup_static_vm | sed "s|/etc/netplan|$T/netplan|g")"
    # Run the generated rollback immediately with network commands stubbed.
    sleep() { :; }; seq() { echo 1; }
    export -f netplan sleep seq
    printf previous > netplan/90-labber-ens18.yaml
    setup_static_vm ens18 192.0.2.20 24 192.0.2.1 ''
    bash "$LABBER_STATE_DIR/ip-apply.sh"
    [ "$(cat netplan/90-labber-ens18.yaml)" = previous ]
    rm netplan/90-labber-ens18.yaml
    touch netplan/00-original.yaml
    setup_static_vm ens18 192.0.2.20 24 192.0.2.1 ''
    bash "$LABBER_STATE_DIR/ip-apply.sh"
    [ ! -e netplan/90-labber-ens18.yaml ]
}

@test "swap mode 2 restores disk swap previously disabled by labber" {
    printf '# disabled by labber setup: /swapfile none swap sw 0 0\n' > fstab
    cp fstab fstab.labber-bak
    eval "$(declare -f st_swap_run | sed "s|/etc/fstab|$T/fstab|g; s|/etc/default/zramswap|$T/zramswap|g")"
    apt_install() { :; }; systemctl() { :; }
    swapon() { printf '%s\n' "$*" > "$T/swapon.args"; }
    SETUP_ANS[swap]=2
    st_swap_run
    grep -qx '/swapfile none swap sw 0 0' fstab
    [ "$(cat swapon.args)" = -a ]
}

@test "setup returns failure after a selected step fails" {
    SETUP_STEPS=(packages)
    detect_virt() { echo lxc; }; setup_admin_name() { :; }
    st_packages_status() { echo todo; }; st_packages_run() { return 23; }
    run do_setup --yes --docker no
    [ "$status" -eq 1 ]
    [[ "$output" == *'failed: packages'* ]]
}

@test "sudo elevation preserves dry-run and all setup options" {
    [ "$EUID" -eq 0 ] || skip "needs root"
    work=$(mktemp -d /tmp/labber-sudo-test.XXXXXX)
    chmod 755 "$work"
    printf '#!/bin/sh\nprintf "<%%s>\\n" "$@"\n' > "$work/sudo"
    chmod 755 "$work/sudo"
    run runuser -u nobody -- env PATH="$work:$PATH" bash "$LABBER" setup --dry-run --docker no --without update
    rm -rf "$work"
    [ "$status" -eq 0 ]
    [[ "$output" == *'<setup>'*'<--dry-run>'*'<--docker>'*'<no>'*'<--without>'*'<update>'* ]]
}

@test "Docker-specific Alloy and update timer omissions select setup again" {
    mkdir -p alloy lib/files home units
    LABBER_BIN="$T/bin-labber" LABBER_LIB="$T/lib" SETUP_USER=root SETUP_DOCKER=1
    SERVICE_BASE="$T/svc"
    touch "$LABBER_BIN"; chmod +x "$LABBER_BIN"
    printf '# labber shell function\n' > home/.bashrc
    user_home() { echo "$T/home"; }
    systemctl() { :; }
    eval "$(declare -f st_labber_status | sed "s|/etc/systemd/system|$T/units|g")"
    [[ "$(st_labber_status)" == todo:* ]]
    printf 'User=root\n' > units/labber-check-updates.service
    [ "$(st_labber_status)" = done ]
    printf '// managed by labber setup\n' > alloy/config.alloy
    eval "$(declare -f st_alloy_status | sed "s|/etc/alloy|$T/alloy|g; s|/etc/systemd/system|$T/units|g")"
    [[ "$(st_alloy_status)" == todo:* ]]
    printf 'prometheus.exporter.cadvisor "docker" {}\nloki.source.docker "containers" {}\n' >> alloy/config.alloy
    mkdir -p units/alloy.service.d; echo User=root > units/alloy.service.d/labber.conf
    [[ "$(st_alloy_status)" == done:* ]]
}

@test "Docker setup status checks both daemon access and the admin group" {
    SETUP_USER=admin
    daemon=down group=missing
    docker() {
        if [[ "$1" == info && "$daemon" == down ]]; then return 1; fi
        echo 'Docker version fixture'
    }
    id() {
        if [[ "$1" == -nG ]]; then
            if [[ "$group" == present ]]; then echo 'admin docker'; else echo admin; fi
        else command id "$@"; fi
    }
    [[ "$(st_docker_status)" == *'daemon is not running'* ]]
    daemon=up
    [[ "$(st_docker_status)" == *'needs the docker group'* ]]
    group=present
    [[ "$(st_docker_status)" == done:* ]]
}

@test "setup does not report success when the Docker update timer cannot start" {
    mkdir units
    SERVICE_BASE="$T/svc" SETUP_USER=root SETUP_DOCKER=1
    eval "$(declare -f st_labber_run | sed "s|/etc/systemd/system|$T/units|g")"
    labber_download() { echo "$T/svc"; }; labber_place() { :; }
    systemctl() { [[ "$1" != enable ]]; }
    _install_shell_fn() { echo 'should not reach shell setup'; }
    run st_labber_run
    [ "$status" -eq 1 ]
    [[ "$output" != *'should not reach shell setup'* ]]
}

@test "a failed Alloy restart cannot pass because an old ready endpoint answers" {
    mkdir -p alloy units
    LABBER_METRICS_DIR="$T/metrics" SETUP_DOCKER=0 SETUP_PROM=http://mon.example:9090
    eval "$(declare -f st_alloy_run | sed "s|/etc/alloy|$T/alloy|g; s|/etc/systemd/system|$T/units|g")"
    pkg_installed() { return 0; }; usermod() { :; }; alloy() { :; }
    systemctl() { [[ "$1" != restart ]]; }
    curl() { echo 'should not reach readiness check'; }
    run st_alloy_run
    [ "$status" -eq 1 ]
    [[ "$output" != *'should not reach readiness check'* ]]
    [ -z "$(state_get alloy_prometheus)" ]
}

@test "setup propagates Docker log, NTP and fail2ban service-start failures" {
    mkdir -p docker jail
    eval "$(declare -f st_dockerlogs_run | sed "s|/etc/docker|$T/docker|g")"
    eval "$(declare -f st_fail2ban_run | sed "s|/etc/fail2ban/jail.d|$T/jail|g")"
    docker() { :; }; apt_install() { :; }; pkg_installed() { return 0; }
    systemctl() { return 1; }
    for step in dockerlogs timesync fail2ban; do
        run "st_${step}_run"
        [ "$status" -eq 1 ]
    done
}
