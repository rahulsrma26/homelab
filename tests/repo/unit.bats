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
    printf '  moving:\n    image: example/moving:latest\n  chan:\n    image: example/chan:stable\n  flavour:\n    image: example/flav:alpine\n  suffixed:\n    image: example/ml:${ML_VERSION:-v3}-openvino\n  bare:\n    image: example/bare\n  defaulted:\n    image: example/def:${DEF_VERSION:-latest}\n  baddigest:\n    image: example/bd:${BD_VERSION:-1.0@None}\n' >> services/demo/docker-compose.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"image example/moving:latest is :latest, a moving tag"* ]]
    [[ "$output" == *"image example/chan:stable is :stable, a moving tag"* ]]
    [[ "$output" == *"image example/flav:alpine is :alpine, a moving tag"* ]]
    [[ "$output" == *"a version variable with text after it can't be pinned to a digest"* ]]
    [[ "$output" == *"image example/bare has no version"* ]]
    [[ "$output" == *"image example/def:latest is :latest, a moving tag"* ]]
    [[ "$output" == *"image example/bd:1.0@None: a digest must be @sha256: and 64 hex characters"* ]]
    [[ "$output" != *"example/app"* && "$output" != *"example/tool"* && "$output" != *"postgres"* && "$output" != *"demo-local"* ]]
}

@test "lint: restart policies: unless-stopped or no; never always or on-failure" {
    mkdir -p services/demo
    cat > services/demo/docker-compose.yml <<'YML'
services:
  app:
    image: example/app:1.2.3
    restart: unless-stopped
  tool:
    image: example/tool:1.0
    restart: "no"
  dep:
    image: example/dep:1.0
    restart: unless-stopped
    depends_on:
      app:
        condition: service_healthy
        restart: true
YML
    run bash tests/repo/lint.sh
    [ "$status" -eq 0 ]
    printf '  boot:\n    image: example/boot:1.0\n    restart: always\n  retry:\n    image: example/retry:1.0\n    restart: on-failure:3\n' >> services/demo/docker-compose.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/demo/docker-compose.yml:17: restart: always — use unless-stopped"* ]]
    [[ "$output" == *"services/demo/docker-compose.yml:20: restart: on-failure:3 — use unless-stopped"* ]]
}

@test "lint: labber.yml accepts only the keys labber reads" {
    mkdir -p services/demo
    printf 'state: [./data]\nowns: ["${DATA_DIR}"]\nhealth: http://localhost:8080/\n' > services/demo/labber.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 0 ]
    printf 'stat: [./data]\n' >> services/demo/labber.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/demo/labber.yml:4: unknown key 'stat'"* ]]
}

@test "lint: a pinned image line has the one shape Renovate rewrites" {
    mkdir -p services/demo
    d=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    printf 'services:\n  a:\n    image: example/a:${A_VERSION:-1@%s}\n' "$d" > services/demo/docker-compose.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 0 ]
    printf '  b:\n    image: "example/b:${B_VERSION:-1@%s}"\n  c:\n    image:  example/c:${C_VERSION:-1@%s}\n' "$d" "$d" >> services/demo/docker-compose.yml
    run bash tests/repo/lint.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker-compose.yml:5: write a pinned image as"* ]]
    [[ "$output" == *"docker-compose.yml:7: write a pinned image as"* ]]
}

@test "bats tests: no bare '! cmd' (bats doesn't fail a test on it; write '! cmd || false')" {
    # a negated command never trips errexit: '! grep -q x f' mid-test checks nothing
    run bash -c "cd '$root' && find . -name '*.bats' -not -path './.git/*' -print0 \
        | xargs -0 grep -nE '(^|;|then)[[:space:]]*! [^=]' | grep -vE '\\|\\| false|^[^:]+:[0-9]+:[[:space:]]*#'"
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "bats tests: no '[ a ] && b' chains (a failing '[ a ]' mid-test doesn't fail it); one check per line" {
    run bash -c "cd '$root' && find . -name '*.bats' -not -path './.git/*' -print0 \
        | xargs -0 grep -nE '^[[:space:]]+([^#]*; )?\\[\\[? .*\\]\\]? && (\\[|grep|! |web_running)' | grep -vE '\\|\\| (skip|false)'"
    [ -z "$output" ] || { echo "$output"; false; }
}
