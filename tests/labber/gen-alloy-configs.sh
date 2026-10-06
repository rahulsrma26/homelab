#!/usr/bin/env bash
# Generate the Alloy configs `labber setup` writes for a VM and for an LXC, into $1,
# so run-unit.sh can check them with the real alloy binary. Runs in the unit-test image.
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
# a Docker host (VM): adds container metrics + container logs
docker() { :; }
SETUP_DOCKER=1 SETUP_VIRT=vm
alloy() { cp "$2" "$out/docker.alloy"; }
printf 'http://mon.example:9090\n\n' | st_alloy_run >/dev/null 2>&1 || true
grep -q 'prometheus.exporter.cadvisor "docker"' "$out/docker.alloy" || { echo "docker config lacks cadvisor" >&2; exit 1; }
grep -q 'loki.source.docker' "$out/docker.alloy" || { echo "docker config lacks container logs" >&2; exit 1; }
