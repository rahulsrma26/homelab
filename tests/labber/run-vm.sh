#!/usr/bin/env bash
# Run labber's integration tests on a test VM over SSH — testing the working tree,
# including uncommitted changes. Nothing outside /tmp/labber-test on the VM is touched
# (except Docker containers/images named labber-test*).
#
# Usage:
#   LABBER_TEST_HOST=user@vm tests/labber/run-vm.sh            # integration tests
#   LABBER_TEST_HOST=user@vm tests/labber/run-vm.sh --network <spare-ip>
#       also moves the VM to <spare-ip> and back (confirmed), then checks an
#       unconfirmed move rolls back. Disconnects SSH for a few minutes.
#
# Optional: LABBER_TEST_KEY=~/.ssh/key   (ssh identity file)
#
# VM requirements: a Debian VM that has been through `labber setup` (Docker, the user
# in the docker group), and passwordless sudo for the user:
#   echo "<user> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/labber-test
set -euo pipefail

host="${LABBER_TEST_HOST:?set LABBER_TEST_HOST=user@vm}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8)
[[ -n "${LABBER_TEST_KEY:-}" ]] && ssh_opts+=(-i "$LABBER_TEST_KEY")
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
remote=/tmp/labber-test
vm() { ssh "${ssh_opts[@]}" "$@"; }

network_ip=""
if [[ "${1:-}" == --network ]]; then network_ip="${2:?--network needs a spare IP}"; fi

# 1. a git snapshot of the working tree (tracked + untracked, minus .gitignore'd files
#    such as .env), plus the labber-test fixture as a service
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo"
(cd "$repo" && git ls-files -co --exclude-standard -- services tools | tar -cf - -T -) | tar -xf - -C "$tmp/repo"
cp -R "$here/fixtures/labber-test" "$tmp/repo/services/labber-test"
(
    cd "$tmp/repo"
    git init -q
    git config uploadpack.allowFilter true
    git add -A
    git -c user.name=labber-test -c user.email=labber-test@localhost commit -qm "working tree snapshot"
)

# 2. ship it, with labber and the tests, to the VM
echo ":: copying working tree to $host:$remote"
tar -czf - -C "$tmp" repo -C "$repo" services/labber tests/labber \
    | vm "$host" "rm -rf $remote && mkdir -p $remote && tar -xzf - -C $remote"

# 3. requirements on the VM
vm "$host" 'sudo -n true' 2>/dev/null \
    || { echo "error: $host needs passwordless sudo — see the header of this script" >&2; exit 1; }
vm "$host" 'command -v bats >/dev/null || sudo -n apt-get install -y -q bats >/dev/null'

# 4. run the integration tests
echo ":: running integration tests on $host"
rc=0
vm "$host" "cd $remote && \
    LABBER=$remote/services/labber \
    LABBER_REPO=file://$remote/repo \
    LABBER_URL=file://$remote/services/labber \
    LABBER_SERVICE_BASE=$remote/services-under-test \
    bats tests/labber/integration.bats tests/labber/commands.bats" || rc=$?

# 5. optional: static IP moves and the automatic rollback
if [[ -n "$network_ip" ]]; then
    user="${host%@*}"; old_ip="${host#*@}"
    echo ":: network: moving $old_ip → $network_ip and back, then an unconfirmed move"
    # gateway/prefix/DNS stay as they are; the move only changes the address
    move_cmd() { # <new-ip>
        echo "cd $remote && sudo -n bash -c 'source services/labber; SETUP_VIRT=vm;
            iface=\$(net_iface); c=\$(net_cidr \$iface);
            setup_static_vm \$iface $1 \${c#*/} \$(net_gw) \"\$(net_dns)\"'"
    }
    confirm_on() { # <ip> → waits for the VM at <ip> and confirms
        local i
        for i in $(seq 24); do
            sleep 5
            if vm -o StrictHostKeyChecking=accept-new "$user@$1" \
                "sudo -n bash $remote/services/labber setup --confirm-ip && getent hosts deb.debian.org >/dev/null"; then
                echo "ok: confirmed on $1, DNS works"; return 0
            fi
        done
        echo "FAIL: never reached $1"; return 1
    }
    vm "$host" "$(move_cmd "$network_ip")"
    confirm_on "$network_ip" || rc=1
    vm "$user@$network_ip" "$(move_cmd "$old_ip")"
    confirm_on "$old_ip" || rc=1

    vm "$host" "$(move_cmd "$network_ip")"
    echo ":: not confirming — waiting for the rollback (~2.5 min)"
    sleep 150
    for i in $(seq 12); do
        if vm "$host" "sudo -n grep -q 'rolled back' /var/lib/labber/ip-result && getent hosts deb.debian.org >/dev/null"; then
            echo "ok: rolled back to $old_ip, DNS works"; break
        fi
        sleep 5
        [[ $i -eq 12 ]] && { echo "FAIL: no rollback seen on $old_ip"; rc=1; }
    done
fi

vm "$host" "rm -rf $remote" || true
exit "$rc"
