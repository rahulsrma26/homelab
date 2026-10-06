#!/usr/bin/env bash
# Run labber's unit tests in a throwaway Debian container (needs only Docker).
# Usage: tests/labber/run-unit.sh [extra bats args, e.g. -f placeholder]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

docker build -q -t labber-unit -f "$here/Dockerfile.unit" "$here" >/dev/null
docker run --rm -v "$repo:/repo:ro" labber-unit bats "$@" /repo/tests/labber/unit.bats
