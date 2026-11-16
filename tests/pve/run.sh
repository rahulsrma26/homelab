#!/usr/bin/env bash
# Run the real-Proxmox tests (tests/pve/*.bats) in a throwaway Proxmox VM ("pve-ci") nested in a
# test Proxmox host: roll it back to its snapshot "clean", start it, copy this working tree in, run
# the tests as root there, stop it. Whatever a test breaks inside (its firewall, a stuck CT) is
# undone by the next run's rollback; the test host itself is only pve-ci's host.
#
#   PVE_TEST_HOST=root@<test host> PVE_CI_VMID=<id> PVE_CI_ADDR=<pve-ci's address> PVE_CI_NET=<test bridge /24 prefix> \
#       tests/pve/run.sh [bats args]
# pve-ci: Proxmox with a ZFS pool "cipool", an internal bridge vmbr1 (<prefix>.1/24, NAT out) for
# its test CTs, a Debian 13 CT template, sanoid, bats, git, jq; snapshot "clean" of it stopped.
#   KEEP=1 …       leave pve-ci running afterwards to look around (the next run rolls back anyway)
#   … --refresh    roll back, upgrade its packages and CT template, take a new "clean"
#
# pve-ci is reached through the test host (ssh -J), so only the test host needs to be reachable.
set -euo pipefail
: "${PVE_TEST_HOST:?PVE_TEST_HOST=root@<test Proxmox host>}" "${PVE_CI_VMID:?PVE_CI_VMID=<pve-ci VM id>}" \
  "${PVE_CI_ADDR:?PVE_CI_ADDR=<pve-ci address>}" "${PVE_CI_NET:?PVE_CI_NET=<pve-ci test bridge /24 prefix>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
host() { ssh -o BatchMode=yes "$PVE_TEST_HOST" "$@"; }
ci()   { ssh -o BatchMode=yes -o ConnectTimeout=5 -J "$PVE_TEST_HOST" "root@$PVE_CI_ADDR" "$@"; }

fresh() {   # pve-ci as in its snapshot "clean", running, answering SSH
    echo ":: pve-ci ($PVE_CI_VMID): back to clean, start"
    host "qm stop $PVE_CI_VMID --skiplock 1 >/dev/null 2>&1 || true; qm rollback $PVE_CI_VMID clean && qm start $PVE_CI_VMID" >/dev/null
    for _ in $(seq 60); do ci true 2>/dev/null && return 0; sleep 3; done
    echo "pve-ci doesn't answer SSH after 3 minutes" >&2; return 1
}
stop_ci() { [[ "${KEEP:-0}" == 1 ]] && { echo ":: KEEP=1: pve-ci left running"; return 0; }; host "qm stop $PVE_CI_VMID" >/dev/null 2>&1 || true; }

if [[ "${1:-}" == --refresh ]]; then
    fresh
    ci 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get full-upgrade -y -qq >/dev/null && pveam update >/dev/null \
        && t=$(pveam available --section system | awk "/debian-13-standard_.*_amd64/{print \$2}" | sort -V | tail -1) \
        && { [ -e "/var/lib/vz/template/cache/$t" ] || pveam download local "$t" >/dev/null; } && pveversion'
    host "qm shutdown $PVE_CI_VMID --timeout 180 && qm delsnapshot $PVE_CI_VMID clean && qm snapshot $PVE_CI_VMID clean --description 'refreshed $(date -u +%F)'"
    echo "✓ pve-ci refreshed: new snapshot clean"; exit 0
fi

trap stop_ci EXIT
fresh
echo ":: copying the working tree in"
(cd "$repo" && git ls-files -co --exclude-standard | tar -cf - -T -) | ci 'rm -rf /root/repo && mkdir -p /root/repo && tar -xf - -C /root/repo'
echo ":: tests/pve/*.bats in pve-ci"
ci "cd /root/repo && KEEP=${KEEP:-0} PVE_CI_NET=$PVE_CI_NET bats $(printf '%q ' "$@") tests/pve/*.bats"
