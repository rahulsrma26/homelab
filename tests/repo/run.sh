#!/usr/bin/env bash
# Run the repo lint in the labber unit-test image (bash 5, GNU tools, git), so it
# behaves the same on a Mac as in CI. Needs only Docker.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
docker build -q -t labber-unit -f "$repo/tests/labber/Dockerfile.unit" "$repo/tests/labber" >/dev/null
# your denylist lives outside the repo: mount it read-only when there is one
deny=()
for f in "${LINT_DENYLIST:-}" "$repo/../lint-denylist.txt" "$repo/personal/lint-denylist.txt"; do
    [[ -n "$f" && -f "$f" ]] && { deny=(-v "$(cd "$(dirname "$f")" && pwd)/$(basename "$f"):/denylist.txt:ro" -e LINT_DENYLIST=/denylist.txt); break; }
done
docker run --rm -v "$repo:/repo:ro" ${deny[@]+"${deny[@]}"} labber-unit bash -c \
    'git config --global --add safe.directory /repo && bash /repo/tests/repo/lint.sh "$@"' lint "$@"
if [[ $# -eq 0 ]]; then
    docker run --rm -v "$repo:/repo:ro" labber-unit bats /repo/tests/repo/unit.bats
fi
