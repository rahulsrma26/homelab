#!/usr/bin/env bash
# Run labber's unit tests in a throwaway Debian container (needs only Docker).
# Usage: tests/labber/run-unit.sh [extra bats args, e.g. -f placeholder]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

docker build -q -t labber-unit -f "$here/Dockerfile.unit" "$here" >/dev/null
rc=0
docker run --rm -v "$repo:/repo:ro" labber-unit bats "$@" /repo/tests/labber/unit.bats || rc=$?

# the Alloy configs setup generates (VM and LXC) must pass the real alloy's check
if [[ $# -eq 0 ]]; then
    out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
    alloy_image=grafana/alloy:v1.20.1    # keep near the version setup installs from apt
    docker run --rm -v "$repo:/repo:ro" -v "$out:/out" labber-unit bash /repo/tests/labber/gen-alloy-configs.sh /out
    for kind in vm lxc docker; do
        if docker run --rm -v "$out:/out:ro" --entrypoint alloy "$alloy_image" fmt "/out/$kind.alloy" >/dev/null; then
            echo "ok - alloy accepts the generated $kind config"
        else
            echo "not ok - alloy rejects the generated $kind config"; rc=1
        fi
    done
fi
exit "$rc"
