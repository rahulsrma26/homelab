#!/usr/bin/env bats
# Lint must inspect content after embedded tabs in both files and git history.
setup() {
    root="$BATS_TEST_DIRNAME/../.."
    cd "$BATS_TEST_TMPDIR"
    mkdir -p labber tests/repo
    cp "$root/labber/labber" labber/
    cp "$root/tests/repo/lint.sh" tests/repo/
    git init -q
    git config user.name test
    git config user.email test@localhost
    git add .; git commit -qm initial
}

@test "lint catches tabbed private addresses in files and committed history" {
    printf 'note\t192.%s.%s.%s\n' 168 42 42 > tabbed.txt
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *'tabbed.txt:1: private IP'* ]]
    git add tabbed.txt; git commit -qm added
    git rm -q tabbed.txt; git commit -qm removed
    run bash tests/repo/lint.sh
    [ "$status" -eq 0 ]
    run bash tests/repo/lint.sh --diff HEAD~2..HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *'tabbed.txt: private IP'* ]]
}

@test "lint: images must be pinned (no :latest, no untagged); digests and local builds are fine" {
    mkdir -p services/demo
    cat > services/demo/docker-compose.yml <<'YML'
services:
  pinned:
    image: example/app:${APP_VERSION:-1.2.3}
  digest:
    image: example/tool:${TOOL_VERSION:-latest@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}
  major:
    image: "postgres:16-alpine"   # a major line is a pin too
  local:
    build: .
    image: demo-local
YML
    run bash tests/repo/lint.sh
    [ "$status" -eq 0 ]
    printf '  moving:\n    image: example/moving:latest\n  chan:\n    image: example/chan:stable\n  bare:\n    image: example/bare\n  defaulted:\n    image: example/def:${DEF_VERSION:-latest}\n' >> services/demo/docker-compose.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"image example/moving:latest is :latest, a moving tag"* ]]
    [[ "$output" == *"image example/chan:stable is :stable, a moving tag"* ]]
    [[ "$output" == *"image example/bare has no version"* ]]
    [[ "$output" == *"image example/def:latest is :latest, a moving tag"* ]]
    [[ "$output" != *"example/app"* && "$output" != *"example/tool"* && "$output" != *"postgres"* && "$output" != *"demo-local"* ]]
}
