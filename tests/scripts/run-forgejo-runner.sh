#!/usr/bin/env bash
# End-to-end test of scripts/forgejo-runner/install.sh in a Debian container with systemd
# (the image from tests/labber/setup). The releases come from a local folder
# (file:// URLs) holding fake runner binaries (a shell script answering --version and
# idling as the daemon); docker and docker.service are stubs. Needs Docker and internet
# (git and nodejs come from Debian).
#   - --dry-run changes nothing; install without registering: user, unit, service stopped
#   - a checksum mismatch is refused and keeps the installed binary
#   - registration answers missing or wrong: refused before anything changes
#   - --register: config mode 600 owned by the runner user, token never printed; it runs
#   - an update (no --version → the latest) keeps the registration and restarts it
#   - --register again with other labels/capacity; --status; --uninstall removes everything
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image=labber-setup-test c="frunner-test-$$"
trap 'docker rm -f "$c" >/dev/null 2>&1 || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }
has() { grep "$@" >/dev/null; }

docker build -q -t "$image" "$repo/tests/labber/setup" >/dev/null
docker run -d --name "$c" --hostname "$c" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
docker cp "$repo/scripts/forgejo-runner/install.sh" "$c:/fr-install.sh"
for _ in $(seq 30); do docker exec "$c" systemctl is-system-running 2>/dev/null | has -E "running|degraded" && break; sleep 1; done
x() { docker exec "$c" bash -c "$1"; }

# a docker stub, and a local "release server" with two fake versions
x 'apt-get update -qq >/dev/null
   groupadd -f docker
   printf "%s\n" "#!/bin/sh" "[ \"\$1\" = info ] && { echo 29.0.0; exit 0; }" "exit 0" > /usr/local/bin/docker; chmod 755 /usr/local/bin/docker
   printf "%s\n" "[Service]" "Type=oneshot" "RemainAfterExit=yes" "ExecStart=/bin/true" > /etc/systemd/system/docker.service
   systemctl daemon-reload && systemctl start docker.service
   arch=$(dpkg --print-architecture)
   for v in 13.9.0 13.9.1; do
     d=/srv/rel/download/v$v; mkdir -p $d; f=forgejo-runner-$v-linux-$arch
     printf "%s\n" "#!/bin/sh" "case \"\$1\" in --version) echo \"forgejo-runner version v$v\" ;; daemon) exec sleep infinity ;; esac" > $d/$f
     (cd $d && sha256sum $f > $f.sha256)
   done
   echo "{\"tag_name\": \"v13.9.1\"}" > /srv/rel/latest.json'
run() { docker exec -e FORGEJO_RUNNER_RELEASES=file:///srv/rel -e FORGEJO_RUNNER_API=file:///srv/rel/latest.json "$@"; }
I=/fr-install.sh
U=0123abcd-0123-4567-89ab-0123456789ab T=0123456789abcdef0123456789abcdef01234567
ver() { x '/usr/local/bin/forgejo-runner --version 2>/dev/null || echo none'; }

out=$(run "$c" bash $I --dry-run --version 13.9.0 </dev/null) || fail "dry-run"
has "install forgejo-runner 13.9.0" <<<"$out" || { echo "$out"; fail "dry-run plan"; }
[[ "$(ver)" == none ]] && ! x 'id forgejo-runner' >/dev/null 2>&1 || fail "dry-run changed something"
pass "--dry-run: shows the plan, changes nothing"

out=$(run "$c" bash $I --version 13.9.0 </dev/null 2>&1) || { echo "$out"; fail "install"; }
[[ "$(ver)" == *v13.9.0 ]] || fail "binary not installed"
x 'command -v git && command -v node' >/dev/null || fail "git/nodejs not installed"
x 'id -nG forgejo-runner' | has -w docker || fail "runner user not in docker"
[[ "$(x 'systemctl is-enabled forgejo-runner; systemctl is-active forgejo-runner || true' | paste -sd' ' -)" == "enabled inactive" ]] || fail "unregistered service should be enabled, stopped"
has "not registered yet" <<<"$out" || fail "no hint to register"
pass "install unregistered: git + nodejs, binary, user in docker, unit enabled, service stopped"

x 'f=$(ls /srv/rel/download/v13.9.1/*.sha256); cp $f /tmp/good.sha; sed -i "s/^./0/" $f'
run "$c" bash $I </dev/null >/dev/null 2>&1 && fail "checksum mismatch accepted"
[[ "$(ver)" == *v13.9.0 ]] || fail "binary replaced despite a bad checksum"
x 'cp /tmp/good.sha $(ls /srv/rel/download/v13.9.1/*.sha256)'
pass "a checksum mismatch is refused, the installed binary stays"

out=$(run "$c" bash $I --register </dev/null 2>&1) && fail "--register without --url accepted"
has -- "--url" <<<"$out" || { echo "$out"; fail "unexpected refusal"; }
out=$(run -e FORGEJO_RUNNER_TOKEN='bad"x' "$c" bash $I --register --url http://forgejo.test --uuid "$U" </dev/null 2>&1) && fail "bad token accepted"
run "$c" bash $I --register --url http://forgejo.test --uuid not-a-uuid </dev/null >/dev/null 2>&1 && fail "bad uuid accepted"
[[ "$(ver)" == *v13.9.0 ]] || fail "a refused registration still updated the binary"
x 'test ! -e /etc/forgejo-runner/config.yml' || fail "a refused registration wrote a config"
pass "missing/wrong registration answers: refused before anything changes"

out=$(run -e FORGEJO_RUNNER_TOKEN=$T "$c" bash $I --register --url http://forgejo.test/ --uuid "$U" --version 13.9.0 </dev/null 2>&1) \
    || { echo "$out"; fail "register"; }
! has "$T" <<<"$out" || fail "the token was printed"
[[ "$(x 'stat -c "%a %U" /etc/forgejo-runner/config.yml')" == "600 forgejo-runner" ]] || fail "config not 600/forgejo-runner"
x 'grep -q "url: \"http://forgejo.test\"" /etc/forgejo-runner/config.yml && grep -q "uuid: \"'"$U"'\"" /etc/forgejo-runner/config.yml && grep -q "\"labber-ci:host\"" /etc/forgejo-runner/config.yml' \
    || { x 'cat /etc/forgejo-runner/config.yml'; fail "config content"; }
[[ "$(x 'systemctl is-active forgejo-runner')" == active ]] || fail "registered runner not running"
[[ "$(x 'stat -c %U /proc/$(systemctl show -p MainPID --value forgejo-runner)')" == forgejo-runner ]] || fail "daemon not running as forgejo-runner"
pass "--register: config 600 (url, uuid, labels), token never printed, runs as forgejo-runner"

sum=$(x 'sha256sum /etc/forgejo-runner/config.yml')
out=$(run "$c" bash $I </dev/null 2>&1) || { echo "$out"; fail "update"; }
[[ "$(ver)" == *v13.9.1 ]] || fail "not updated to the latest"
[[ "$(x 'sha256sum /etc/forgejo-runner/config.yml')" == "$sum" ]] || fail "update changed the config"
[[ "$(x 'systemctl is-active forgejo-runner')" == active ]] || fail "not running after the update"
has "13.9.0 → 13.9.1" <<<"$out" || fail "update not reported"
pass "update to the latest: registration kept, still running"

run -e FORGEJO_RUNNER_TOKEN=$T "$c" bash $I --register --url http://forgejo.test --uuid "$U" --labels "a:host,b:host" --capacity 2 </dev/null >/dev/null 2>&1 \
    || fail "re-register"
x 'grep -q "capacity: 2" /etc/forgejo-runner/config.yml && grep -q "\"a:host\"" /etc/forgejo-runner/config.yml && grep -q "\"b:host\"" /etc/forgejo-runner/config.yml && ! grep -q labber-ci /etc/forgejo-runner/config.yml' \
    || fail "labels/capacity not rewritten"
x "bash $I --status" | has -E "registered +yes: http://forgejo.test" || fail "status"
pass "--register again: new labels and capacity; --status shows the registration"

run "$c" bash $I --uninstall --yes </dev/null >/dev/null || fail "uninstall"
x 'test ! -e /usr/local/bin/forgejo-runner && test ! -e /etc/forgejo-runner && test ! -e /var/lib/forgejo-runner && test ! -e /etc/systemd/system/forgejo-runner.service && ! id forgejo-runner 2>/dev/null' \
    || fail "uninstall left something"
pass "--uninstall removes the binary, unit, user, config and work folder"
