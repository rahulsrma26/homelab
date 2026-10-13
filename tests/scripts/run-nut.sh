#!/usr/bin/env bash
# End-to-end test of scripts/nut-setup.sh in Debian containers with systemd (the image
# from tests/labber/setup). A simulated UPS (dummy-ups, NUT_SETUP_DUMMY=1) stands in for
# the USB cable. Needs only Docker (and internet: the script installs the NUT packages).
#
#   server (policy lb) + client (policy timer, 30 s) + monitor, on one Docker network:
#   - each answers upsc; the client's upsmon logs in to the server
#   - a wrong client password is caught by the script
#   - re-running the server keeps its passwords
#   - power cut: the dummy UPS goes "on battery" → the client powers off after its timer;
#     then "low battery" → the server powers off too
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image=labber-setup-test net="nut-test-$$"
srv="nut-srv-$$" cli="nut-cli-$$" mon="nut-mon-$$"
cleanup() { docker rm -f "$srv" "$cli" "$mon" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

docker build -q -t "$image" "$repo/tests/labber/setup" >/dev/null
docker network create "$net" >/dev/null
for c in "$srv" "$cli" "$mon"; do
    docker run -d --name "$c" --hostname "$c" --network "$net" --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
    docker cp "$repo/scripts/nut-setup.sh" "$c:/nut-setup.sh"
done
for c in "$srv" "$cli" "$mon"; do
    for _ in $(seq 30); do docker exec "$c" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 1; done
    docker exec "$c" bash -c 'apt-get update -qq' >/dev/null
done
run() { local c="$1"; shift; docker exec -e NUT_SETUP_DUMMY=1 "$c" bash /nut-setup.sh --yes "$@"; }

# ── server ──
run "$srv" --role server --policy lb --ups eaton >/dev/null || fail "server setup"
docker exec "$srv" upsc eaton@localhost ups.status | grep -q OL || fail "server upsc"
docker exec "$srv" grep -q "POWERDOWNFLAG /etc/killpower" /etc/nut/upsmon.conf || fail "lb policy: no POWERDOWNFLAG"
docker exec "$srv" ss -ltn | grep -q "0.0.0.0:3493" || fail "upsd not listening on 0.0.0.0"
[[ "$(docker exec "$srv" stat -c %G /etc/nut/upsd.users)" == nut ]] || fail "upsd.users not group nut"
pass "server (lb): UPS answers, killpower flag set, files readable by nut"
pw=$(docker exec "$srv" awk '$1=="[client]"{f=1;next} /^\[/{f=0} f&&$1=="password"{print $3;exit}' /etc/nut/upsd.users)
[[ -n "$pw" ]] || fail "no client password"

run "$srv" --role server --policy lb --ups eaton >/dev/null || fail "server re-run"
pw2=$(docker exec "$srv" awk '$1=="[client]"{f=1;next} /^\[/{f=0} f&&$1=="password"{print $3;exit}' /etc/nut/upsd.users)
[[ "$pw" == "$pw2" ]] || fail "re-run changed the client password"
docker exec "$srv" bash -c 'ls -d /etc/nut.bak-*' >/dev/null || fail "no backup of /etc/nut"
pass "server re-run: passwords kept, old config backed up"

# ── client ──
if out=$(run "$cli" --role client --server "$srv" --ups eaton --password wrong --policy timer --timer 30 2>&1); then
    fail "wrong password not caught"
fi
grep -q "couldn't log in" <<<"$out" || fail "client setup failed, but not because of the password: $(tail -2 <<<"$out")"
pass "client: wrong password caught"
run "$cli" --role client --server "$srv" --ups eaton --password "$pw" --policy timer --timer 30 >/dev/null || fail "client setup"
docker exec "$cli" systemctl is-active --quiet nut-monitor || fail "client upsmon not running"
docker exec "$srv" upsc -c eaton@localhost 2>/dev/null | grep -q . || fail "server sees no logged-in client"
pass "client (timer 30 s): logged in to the server"

# ── monitor ──
run "$mon" --role monitor --ups apc >/dev/null || fail "monitor setup"
docker exec "$mon" upsc apc@localhost ups.status | grep -q OL || fail "monitor upsc"
! docker exec "$mon" systemctl is-active --quiet nut-monitor || fail "monitor runs upsmon"
pass "monitor: UPS answers, no upsmon"

# ── power cut ──
docker exec "$srv" bash -c 'sed -i "s/^ups.status: .*/ups.status: OB DISCHRG/" /etc/nut/dummy.dev'
for _ in $(seq 90); do [[ "$(docker inspect -f '{{.State.Running}}' "$cli")" == false ]] && break; sleep 2; done
[[ "$(docker inspect -f '{{.State.Running}}' "$cli")" == false ]] || fail "client didn't power off after its timer"
pass "on battery: client powered off after its timer"
docker exec "$srv" journalctl -t nut -b --no-pager | grep -q ONBATT || fail "server didn't log ONBATT"
docker exec "$srv" bash -c 'sed -i "s/^ups.status: .*/ups.status: OB DISCHRG LB/" /etc/nut/dummy.dev'
for _ in $(seq 60); do [[ "$(docker inspect -f '{{.State.Running}}' "$srv")" == false ]] && break; sleep 2; done
[[ "$(docker inspect -f '{{.State.Running}}' "$srv")" == false ]] || fail "server didn't power off at low battery"
pass "low battery: server powered off"

# ── fsd-timer (like w680): after the timer the server shuts down its clients, then itself ──
srv2="nut-srv2-$$" cli2="nut-cli2-$$"
cleanup2() { docker rm -f "$srv2" "$cli2" >/dev/null 2>&1 || true; cleanup; }
trap cleanup2 EXIT
for c in "$srv2" "$cli2"; do
    docker run -d --name "$c" --hostname "$c" --network "$net" --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
    docker cp "$repo/scripts/nut-setup.sh" "$c:/nut-setup.sh"
    for _ in $(seq 30); do docker exec "$c" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 1; done
    docker exec "$c" bash -c 'apt-get update -qq' >/dev/null
done
run "$srv2" --role server --policy fsd-timer --timer 30 --ups cyberpower >/dev/null || fail "fsd-timer server setup"
pw=$(docker exec "$srv2" awk '$1=="[client]"{f=1;next} /^\[/{f=0} f&&$1=="password"{print $3;exit}' /etc/nut/upsd.users)
run "$cli2" --role client --server "$srv2" --ups cyberpower --password "$pw" --policy lb >/dev/null || fail "lb client setup"
docker exec "$srv2" bash -c 'sed -i "s/^ups.status: .*/ups.status: OB DISCHRG/" /etc/nut/dummy.dev'
for _ in $(seq 60); do [[ "$(docker inspect -f '{{.State.Running}}' "$srv2")" == false ]] && break; sleep 2; done
[[ "$(docker inspect -f '{{.State.Running}}' "$cli2")" == false ]] || fail "fsd: client still running"
[[ "$(docker inspect -f '{{.State.Running}}' "$srv2")" == false ]] || fail "fsd: server still running after its timer"
c_end=$(docker inspect -f '{{.State.FinishedAt}}' "$cli2"); s_end=$(docker inspect -f '{{.State.FinishedAt}}' "$srv2")
[[ "$c_end" < "$s_end" ]] || fail "fsd: server went down before its client ($s_end vs $c_end)"
pass "fsd-timer: after 30 s on battery the client went down first, then the server"
echo "all NUT tests passed"
