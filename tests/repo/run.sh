#!/usr/bin/env bash
# Run the repo lint in the labber unit-test image (bash 5, GNU tools, git), so it
# behaves the same on a Mac as in CI. Needs only Docker.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
docker build -q -t labber-unit -f "$repo/tests/labber/Dockerfile.unit" "$repo/tests/labber" >/dev/null
docker run --rm -v "$repo:/repo:ro" labber-unit bash -c \
    'git config --global --add safe.directory /repo && bash /repo/tests/repo/lint.sh'
