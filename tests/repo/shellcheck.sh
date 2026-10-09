#!/usr/bin/env bash
# Runs shellcheck on every shell script in the repo, pinned to one version (needs only Docker),
# so a local run and CI agree.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
image=koalaman/shellcheck:v0.11.0
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard -- '*.sh')
docker run --rm -v "$repo:/mnt:ro" -w /mnt "$image" -S warning labber/labber services/labber "${files[@]}"
echo "shellcheck: ok (${#files[@]} scripts + labber + the forwarder)"
