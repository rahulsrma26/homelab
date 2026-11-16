#!/usr/bin/env bash
# Generate the Alloy configs `labber setup` writes for a VM and for an LXC, into $1,
# so run-unit.sh can check them with the real alloy binary. Runs in the unit-test image.
# the variables it sets are read by the sourced labber functions
# shellcheck disable=SC2034
set -euo pipefail
out="$1"
# shellcheck disable=SC1090
source "${LABBER:-/repo/labber/labber}"
set +u
LABBER_STATE_DIR=$(mktemp -d)
pkg_installed() { [ "$1" = alloy ]; }
usermod() { :; }; systemctl() { :; }; curl() { :; }
# "alloy fmt <file>" is where the step validates — capture the file instead
alloy() { cp "$2" "$out/$SETUP_VIRT.alloy"; }
SETUP_DOCKER=0
for SETUP_VIRT in vm lxc; do
    printf 'http://mon.example:9090\n\n' | st_alloy_run >/dev/null 2>&1 || true
    [ -s "$out/$SETUP_VIRT.alloy" ] || { echo "no $SETUP_VIRT config generated" >&2; exit 1; }
done
# a Docker host (VM): adds container metrics + container logs; with a push token
docker() { :; }
SETUP_DOCKER=1 SETUP_VIRT=vm
PUSH_TOKEN_FILE=$(mktemp -u); SETUP_PUSHTOKEN=0123456789abcdef0123456789abcdef
alloy() { cp "$2" "$out/docker.alloy"; }
printf 'http://mon.example:9090\n\n' | st_alloy_run >/dev/null 2>&1 || true
grep -q 'prometheus.exporter.cadvisor "docker"' "$out/docker.alloy" || { echo "docker config lacks cadvisor" >&2; exit 1; }
grep -q 'loki.source.docker' "$out/docker.alloy" || { echo "docker config lacks container logs" >&2; exit 1; }
[ "$(grep -c "bearer_token_file = \"$PUSH_TOKEN_FILE\"" "$out/docker.alloy")" -eq 2 ] || { echo "the push token isn't on both endpoints" >&2; exit 1; }
[ "$(stat -c %a "$PUSH_TOKEN_FILE")" = 600 ] || [ "$(stat -c %a "$PUSH_TOKEN_FILE")" = 640 ] || { echo "the token file is readable by others" >&2; exit 1; }
! grep -q '@AUTH@' "$out/vm.alloy" "$out/lxc.alloy" || { echo "an unfilled @AUTH@" >&2; exit 1; }
