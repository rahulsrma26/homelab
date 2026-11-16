#!/usr/bin/env bash
# The tests of each service a change touches (Forgejo CI's services job): its own tests
# (tests/<service>/run*.sh) and tests/services/run.sh (every template's Compose config, then the
# real-app checks of those services). A change to tests/services/ or to this script runs them all.
# Usage: service-tests.sh BASE (the commit to compare HEAD with); --list: only print what would run.
set -euo pipefail
cd "$(dirname "$0")/../.."
list=0; [[ "${1:-}" == --list ]] && { list=1; shift; }
base="${1:?usage: service-tests.sh [--list] BASE}"

changed=() all=0
while IFS= read -r path; do
    if [[ "$path" == tests/services/* || "$path" == tests/ci/service-tests.sh ]]; then all=1; continue; fi
    rest="${path#*/}" name="${rest%%/*}"                     # services/<name>/… or tests/<name>/…
    if [[ "$name" != "$rest" && "$name" != labber && -d "services/$name" ]]; then changed+=("$name"); fi   # labber: its own job
done < <(git diff --name-only "$base" HEAD -- services/ tests/)

if [[ "$all" == 1 ]]; then mapfile -t svcs < <(find services -mindepth 1 -maxdepth 1 -type d ! -name labber -printf '%f\n' | sort)
else mapfile -t svcs < <(printf '%s\n' "${changed[@]}" | sort -u | grep . || true)
fi

runs=()
for s in "${svcs[@]}"; do
    for t in tests/"$s"/run*.sh; do [[ -f "$t" ]] && runs+=("$t"); done
done
if [[ "${#svcs[@]}" -gt 0 ]]; then
    if [[ "$all" == 1 ]]; then runs+=("tests/services/run.sh"); else runs+=("tests/services/run.sh ${svcs[*]}"); fi
fi

[[ "${#runs[@]}" -gt 0 ]] || { echo "no service changed: no service tests"; exit 0; }
fail=0
for r in "${runs[@]}"; do
    if [[ "$list" == 1 ]]; then echo "$r"; continue; fi
    echo "::group::$r"
    # shellcheck disable=SC2086   # "run.sh svc svc": its arguments
    bash $r || { echo "FAILED: $r"; fail=1; }
    echo "::endgroup::"
done
exit "$fail"
