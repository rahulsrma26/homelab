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
