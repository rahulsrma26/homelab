#!/usr/bin/env bats
# Real Git repositories, with no external forge/network dependency.
setup() {
    LABBER="${LABBER:-$BATS_TEST_DIRNAME/../../labber/labber}"
    source "$LABBER"
    set +u
    T="$BATS_TEST_TMPDIR"
    SOURCE_CONFIG="$T/source.conf"
    export LABBER_SOURCE_CONFIG="$SOURCE_CONFIG"
    unset LABBER_SOURCE LABBER_REF LABBER_REPO LABBER_URL
    CLONE_RETRY_DELAY=0
    export CLONE_RETRY_DELAY
    git init -qb main "$T/origin"
    mkdir -p "$T/origin/services/demo" "$T/origin/tools/demo"
    printf 'original\n' > "$T/origin/services/demo/config.txt"
    printf 'retired\n' > "$T/origin/services/demo/retired.txt"
    printf 'KEY=default\n' > "$T/origin/services/demo/.env.example"
    printf '.env\nignored/\n' > "$T/origin/.gitignore"
    printf '#!/bin/bash\ncat data.txt\n' > "$T/origin/tools/demo/install.sh"
    printf 'tool-original\n' > "$T/origin/tools/demo/data.txt"
    cp -R "$(dirname "$LABBER")" "$T/origin/labber"
    git -C "$T/origin" add -A
    git -C "$T/origin" -c user.name=t -c user.email=t@localhost commit -qm base
    BASE=$(git -C "$T/origin" rev-parse HEAD)
}

@test "source: default stays GitHub main and URL overrides do not inherit a saved ref" {
    source_resolve '' ''
    [ "$REPO" = https://github.com/rahulsrma26/homelab.git ]
    [ "$SOURCE_REF" = main ] && [ "$SOURCE_CUSTOM" -eq 0 ]
    printf 'source=https://git.example.test/owner/homelab.git\nref=production\n' > "$SOURCE_CONFIG"
    LABBER_SOURCE="file://$T/origin" source_resolve '' ''
    [ "$REPO" = "file://$T/origin" ] && [ -z "$SOURCE_REF" ]
    source_resolve "file://$T/origin" main
    [ "$SOURCE_REF" = main ]
}

@test "source: saved settings round-trip spaces, timers read them, reset repairs stale paths" {
    mv "$T/origin" "$T/local checkout"
    run bash "$LABBER" source set "$T/local checkout"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$SOURCE_CONFIG")" = 644 ]
    run bash "$LABBER" source show
    [ "$status" -eq 0 ] && [[ "$output" == *"source=$T/local checkout"*"mode=worktree"* ]]
    mv "$T/local checkout" "$T/moved"
    run bash "$LABBER" source show
    [ "$status" -ne 0 ]
    run bash "$LABBER" source reset
    [ "$status" -eq 0 ] && [ ! -e "$SOURCE_CONFIG" ]
    run bash "$LABBER" source set "file://$T/moved" main
    [ "$status" -eq 0 ]
    run bash "$LABBER" source show
    [[ "$output" == *"ref=main"*"mode=git"* ]]
}

@test "source: config is data; overrides and refs cannot execute shell code or leak URL passwords" {
    printf 'source=$(touch %s/escaped)\nref=main\n' "$T" > "$SOURCE_CONFIG"
    run bash "$LABBER" source show
    [ "$status" -ne 0 ] && [ ! -e "$T/escaped" ]
    # set can repair malformed config, and HTTP/SSH URL passwords are rejected.
    printf 'broken=true\n' > "$SOURCE_CONFIG"
    run bash "$LABBER" source set "file://$T/origin" main
    [ "$status" -eq 0 ]
    for src in 'https://user:dummy-password@git.example.test/repo.git' 'ssh://user:dummy-password@git.example.test/repo.git' '-bad' 'ext::echo @x:y'; do
        run bash "$LABBER" --source "$src" source show
        [ "$status" -ne 0 ] && [[ "$output" != *dummy-password* ]]
    done
    run bash "$LABBER" --ref 'main:other' source show
    [ "$status" -ne 0 ]
    run bash "$LABBER" --source
    [ "$status" -ne 0 ]
    run bash "$LABBER" --source "$T/origin/services" source show
    [ "$status" -ne 0 ]
    run bash "$LABBER" --source "$T/origin" --ref main source show
    [ "$status" -ne 0 ]
}

@test "source: working tree includes dirty/new files and deletions, excluding ignored state and even tracked .env" {
    printf 'dirty\n' > "$T/origin/services/demo/config.txt"
    printf 'new\n' > "$T/origin/services/demo/new file.txt"
    rm "$T/origin/services/demo/retired.txt"
    mkdir -p "$T/origin/services/demo/ignored"
    echo excluded > "$T/origin/services/demo/ignored/private"
    echo excluded > "$T/origin/services/demo/.env"
    git -C "$T/origin" add -f services/demo/.env
    echo excluded > "$T/origin/services/demo/config.txt.labber-bak"
    echo excluded > "$T/origin/services/demo/.labber-base"
    before=$(git -C "$T/origin" status --porcelain)
    source_resolve "$T/origin" ''
    dir=$(clone_repo_dir services/)
    [ "$(cat "$dir/services/demo/config.txt")" = dirty ]
    [ "$(cat "$dir/services/demo/new file.txt")" = new ]
    [ ! -e "$dir/services/demo/retired.txt" ] && [ ! -e "$dir/services/demo/.env" ]
    [ ! -e "$dir/services/demo/ignored" ] && [ ! -e "$dir/services/demo/config.txt.labber-bak" ]
    [ ! -e "$dir/services/demo/.labber-base" ] && [ ! -d "$dir/tools" ]
    [ "$(git -C "$dir/services/demo" rev-parse --show-prefix)" = services/demo/ ]
    [ "$(git -C "$T/origin" status --porcelain)" = "$before" ]
    [ "$(git -C "$T/origin" rev-parse HEAD)" = "$BASE" ]
    rm -rf "$dir"
}

@test "source: working-tree symlinks and submodules fail rather than reading through them" {
    source_resolve "$T/origin" ''
    ln -s /etc/passwd "$T/origin/services/demo/link"
    run clone_repo_dir services/
    [ "$status" -ne 0 ] && [[ "$output" == *unsupported* ]]
    rm "$T/origin/services/demo/link"
    # Simulate a tracked submodule (no external checkout/network).
    git -C "$T/origin" update-index --add --cacheinfo "160000,$BASE,services/demo/sub"
    mkdir "$T/origin/services/demo/sub"
    run clone_repo_dir services/
    [ "$status" -ne 0 ] && [[ "$output" == *unsupported* ]]
}

@test "source: Git URLs select a branch, tag or SHA and ignore dirty files" {
    git -C "$T/origin" switch -qc candidate
    echo candidate > "$T/origin/services/demo/config.txt"
    git -C "$T/origin" add -A
    git -C "$T/origin" -c user.name=t -c user.email=t@localhost commit -qm candidate
    git -C "$T/origin" tag v-test
    git -C "$T/origin" -c user.name=t -c user.email=t@localhost tag -am test annotated
    sha=$(git -C "$T/origin" rev-parse HEAD)
    echo dirty > "$T/origin/services/demo/config.txt"
    for ref in candidate v-test annotated "$sha"; do
        source_resolve "file://$T/origin" "$ref"
        dir=$(clone_repo_dir services/)
        [ "$(cat "$dir/services/demo/config.txt")" = candidate ]
        [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]
        rm -rf "$dir"
    done
    source_resolve "file://$T/origin" main
    dir=$(clone_repo_dir services/)
    [ "$(cat "$dir/services/demo/config.txt")" = original ]
    rm -rf "$dir"
    source_resolve "file://$T/origin" missing
    run clone_repo_dir services/
    [ "$status" -ne 0 ]
    [[ "$output" == *"couldn't find remote ref missing"* ]]
}

@test "source: local updates use normal edit/deletion protection and retain target .env" {
    mkdir "$T/installed"
    cp "$T/origin/services/demo/"* "$T/installed/"
    record_base "$T/origin/services/demo" "$T/installed"
    echo target-secret > "$T/installed/.env"
    echo locally-edited > "$T/installed/config.txt"
    echo new-source > "$T/origin/services/demo/config.txt"
    rm "$T/origin/services/demo/retired.txt"
    source_resolve "$T/origin" ''
    dir=$(clone_repo_dir services/)
    copy_svc_files "$dir/services/demo" "$T/installed" </dev/null
    [ "$(cat "$T/installed/.env")" = target-secret ]
    [ "$(cat "$T/installed/config.txt")" = locally-edited ]
    [ "$(cat "$T/installed/config.txt.labber-new")" = new-source ]
    [ ! -e "$T/installed/retired.txt" ]
    rm -rf "$dir"
}

@test "source: tools and labber assets use the selected working tree, not GitHub" {
    echo dirty-tool > "$T/origin/tools/demo/data.txt"
    echo local-asset > "$T/origin/labber/files/local-test.txt"
    source_resolve "$T/origin" ''
    run do_tool demo
    [ "$status" -eq 0 ] && [[ "$output" == *dirty-tool* ]]
    mkdir "$T/download"
    dir=$(labber_download "$T/download")
    [ "$(cat "$dir/files/local-test.txt")" = local-asset ]
    [ "$(labber_version_of "$dir")" = "$VERSION" ]
    # setup assets obey selection even when the running script has adjacent files/.
    labber_need_files
    [ "$(cat "$LABBER_FILES/local-test.txt")" = local-asset ]
}

@test "source: same-version self-update installs changed assets and subsequent check is a no-op" {
    LABBER_LIB="$T/lib/labber" LABBER_BIN="$T/bin/labber"
    mkdir -p "$T/lib" "$T/bin" "$T/home"
    HOME="$T/home"
    labber_place "$T/origin/labber"
    source_resolve "$T/origin" ''
    echo dirty-asset > "$T/origin/labber/files/local-test.txt"
    apt-get() { return 0; }
    run do_update
    [ "$status" -eq 0 ] && [[ "$output" == *"labber updated"* ]]
    [ "$(cat "$LABBER_LIB/files/local-test.txt")" = dirty-asset ]
    run do_update
    [ "$status" -eq 0 ] && [[ "$output" == *"already on latest"* ]]
}

@test "source: chosen ref also controls legacy installed-file history" {
    git -C "$T/origin" switch -qc other
    echo only-other-branch > "$T/origin/services/demo/config.txt"
    git -C "$T/origin" add -A
    git -C "$T/origin" -c user.name=t -c user.email=t@localhost commit -qm other
    git -C "$T/origin" -c user.name=t -c user.email=t@localhost tag -am test annotated
    echo only-other-branch > "$T/installed"
    source_resolve "file://$T/origin" other
    was_repo_version services/demo/config.txt "$T/installed"
    drop_history
    source_resolve "file://$T/origin" annotated
    was_repo_version services/demo/config.txt "$T/installed"
    drop_history
    source_resolve "file://$T/origin" main
    run was_repo_version services/demo/config.txt "$T/installed"
    [ "$status" -ne 0 ]
    drop_history
}

@test "source: setup forwards environment-selected source and every setup argument through sudo" {
    [ "$EUID" -eq 0 ] || skip "needs root for a non-root invocation"
    local runroot
    runroot=$(mktemp -d /tmp/labber-sudo-source-XXXXXX)
    chmod 777 "$runroot"
    mkdir "$runroot/bin"; cp "$LABBER" "$runroot/labber"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/args"\n' "$runroot" > "$runroot/bin/sudo"
    chmod 755 "$runroot/bin/sudo"
    run setpriv --reuid=65534 --regid=65534 --clear-groups env \
        PATH="$runroot/bin:$PATH" LABBER_SOURCE_CONFIG="$runroot/no-config" \
        LABBER_SOURCE='https://git.example.test/owner/homelab.git' LABBER_REF=candidate \
        bash "$runroot/labber" setup --yes --docker no --without update,network
    echo "$output"
    [ "$status" -eq 0 ]
    printf '%s\n' bash "$runroot/labber" --source 'https://git.example.test/owner/homelab.git' --ref candidate \
        setup --yes --docker no --without update,network > "$runroot/expected"
    cmp "$runroot/args" "$runroot/expected"
    rm -rf "$runroot"
}

@test "source: global options cannot be silently discarded by source set or reset" {
    run bash "$LABBER" --ref main source set "file://$T/origin"
    [ "$status" -ne 0 ] && [ ! -e "$SOURCE_CONFIG" ]
    run bash "$LABBER" --source "$T/origin" source reset
    [ "$status" -ne 0 ]
    run bash "$LABBER" help --source "$T/origin"
    [ "$status" -ne 0 ] && [[ "$output" == *"must go before"* ]]
}

@test "source: Bash and zsh shell functions keep go and argument forwarding working with source options" {
    HOME="$T/home"; mkdir -p "$HOME" "$T/destination with spaces"; unset SUDO_USER
    _install_shell_fn
    cat > "$T/mock" <<'MOCK'
#!/bin/bash
if [[ "${*: -1}" == go ]]; then
    [[ "${*: -2:1}" != missing ]] || exit 42
    printf '%s\n' "$DESTINATION"
else
    printf '%s\n' "$@"
fi
MOCK
    chmod +x "$T/mock"
    sed "s|/usr/local/bin/labber|$T/mock|g" "$HOME/.bashrc" > "$T/function"
    export DESTINATION="$T/destination with spaces"
    for shell in bash zsh; do
        run "$shell" -c 'source "$1"; labber --source "local checkout" --ref main demo go && pwd' _ "$T/function"
        [ "$status" -eq 0 ] && [ "$output" = "$DESTINATION" ]
        run "$shell" -c 'source "$1"; labber --source "local checkout" demo logs --tail 5' _ "$T/function"
        [ "$status" -eq 0 ] && [ "$output" = $'--source\nlocal checkout\ndemo\nlogs\n--tail\n5' ]
        run "$shell" -c 'source "$1"; labber --source "local checkout" missing go' _ "$T/function"
        [ "$status" -eq 42 ]
    done
}

@test "source: a missing saved checkout does not block local operations or help, but fetches fail" {
    do_source set "$T/origin"
    mv "$T/origin" "$T/moved"
    mkdir -p "$T/installed/demo"
    touch "$T/installed/demo/docker-compose.yml"
    run env LABBER_SERVICE_BASE="$T/installed" bash "$LABBER" demo go
    [ "$status" -eq 0 ] && [ "$output" = "$T/installed/demo" ]
    run bash "$LABBER" help
    [ "$status" -eq 0 ]
    run bash "$LABBER" tool ls
    [ "$status" -ne 0 ] && [[ "$output" == *"local source is not a directory"* ]]
    run bash "$LABBER" source show
    [ "$status" -ne 0 ]
}
