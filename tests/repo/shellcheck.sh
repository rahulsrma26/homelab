#!/usr/bin/env bash
# Runs shellcheck on every shell script in the repo, pinned to one version (needs only Docker),
# so a local run and CI agree.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
image=koalaman/shellcheck:v0.11.0
files=()
# (only files that exist: a deleted but not yet committed file is still in git's index)
while IFS= read -r -d '' f; do [[ -f "$f" ]] && files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard -- '*.sh')
# scripts without a .sh extension: anything with a bash shebang outside services/ and tools/
while IFS= read -r -d '' f; do
    [[ -f "$f" && "$f" != *.sh && "$f" != labber/labber && "$f" != services/labber ]] || continue
    head -c 64 "$f" 2>/dev/null | head -1 | grep -qE '^#!.*\b(bash|sh)\b' && files+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard -- scripts .githooks)
docker run --rm -v "$repo:/mnt:ro" -w /mnt "$image" -S warning labber/labber services/labber "${files[@]}"
echo "shellcheck: ok (${#files[@]} scripts + labber + the forwarder)"
