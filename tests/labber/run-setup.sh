#!/usr/bin/env bash
# Run `labber setup` from scratch in a fresh Debian container with systemd, the way it
# runs on a new machine: piped (`bash <(curl …) setup`), as root, answering every
# question. Then setup-<mode>.bats checks the result, including that a second run finds
# nothing left to do. Tests the working tree; needs only Docker (and internet: setup
# installs packages, Alloy, Docker and zsh plugins).
#
#   tests/labber/run-setup.sh [lxc|vm|auto|both]     (default: both = all three, a few minutes)
#
#   lxc  root only, no Docker — like a new Proxmox LXC
#   vm   treated as a VM: an admin user (created beforehand, as the Debian installer
#        does) gets sudo and becomes the user labber, zsh and fzf are set up for; root
#        SSH off; Docker (nested, on its own storage volume); the second run goes
#        through `sudo labber setup` as that user
#   auto the lxc case as one unattended command: --yes and flags, no terminal, no input
#
# A container can't cover (the real VM tests do — see run-vm.sh): time sync, swap/zram,
# the guest agent actually talking to Proxmox, and static IPs.
set -euo pipefail
# macOS tar would add ._* metadata files to every archive
export COPYFILE_DISABLE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
modes="${1:-both}"; [[ "$modes" == both ]] && modes="lxc vm auto"
image=labber-setup-test

# what setup downloads, from the working tree: labber's tarball (LABBER_URL) and a
# git snapshot of the repo (LABBER_REPO, for tools/: fzf and the p10k config)
tmp=$(mktemp -d)
containers=()
cleanup() {
    local c
    for c in "${containers[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1 || true; done
    rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/t/repo" "$tmp/bundle/homelab-main"
cp -R "$repo/labber" "$tmp/bundle/homelab-main/labber"
tar -czf "$tmp/t/labber.tar.gz" -C "$tmp/bundle" homelab-main
(cd "$repo" && git ls-files -co --exclude-standard -- tools | tar -cf - -T -) | tar -xf - -C "$tmp/t/repo"
(cd "$tmp/t/repo" && git init -q && git config uploadpack.allowFilter true && git add -A \
    && git -c user.name=t -c user.email=t@localhost commit -qm snapshot)
cp "$repo/labber/labber" "$here"/setup-*.bats "$tmp/t/"
docker build -q -t "$image" "$here/setup" >/dev/null
# a throwaway key pair for setup's "paste your public key" question, made fresh each
# run (deleted with $tmp) — no fixed key in the repo, nobody else holds the private half
ssh-keygen -q -t ed25519 -N '' -C labber-setup-test -f "$tmp/id_ed25519"
key=$(cat "$tmp/id_ed25519.pub")

run_mode() {
    local mode="$1" name="labber-setup-$1-$$" answers state
    containers+=("$name")
    # Docker inside needs its own storage (overlay on overlay doesn't work)
    docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd "$image" >/dev/null
    # copied in and handed to root, as on a real machine: git won't clone a repo that
    # belongs to another user, and both a bind mount and docker cp keep the host's user id
    docker cp "$tmp/t" "$name:/t"
    docker exec "$name" chown -R root:root /t
    for _ in $(seq 30); do
        state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == running || "$state" == degraded ]] && break
        sleep 1
    done

    if [[ "$mode" == lxc ]]; then
        # treat it as a VM? n (→ LXC) · Docker services? n · checklist: a (all), Enter (run)
        # locale: Enter · timezone, hostname: Enter · SSH key: paste (an LXC has no test
        # login) · Prometheus URL · Loki URL: Enter · network: 3 (skip)
        answers=$'n\nn\na\n\n'$'\n'$'\n\n'"$key"$'\n'$'http://127.0.0.1:9090\n\n'$'3\n'
    else
        # the user the Debian installer creates on a VM; setup adds it to sudo
        docker exec "$name" useradd -m -s /bin/bash admin
        # treat it as a VM? y · Docker services? Enter (yes) · checklist: the pre-selected
        # steps, minus 6 (time sync: a container uses the host's clock) plus 20 (fail2ban),
        # Enter (run) · locale: Enter · admin username · timezone, hostname: Enter ·
        # SSH key: paste · logged in? y · Prometheus URL · Loki URL: Enter
        answers=$'y\n\n6 20\n\n'$'\n'$'admin\n'$'\n\n'"$key"$'\ny\n'$'http://127.0.0.1:9090\n\n'
    fi
    echo ":: [$mode] labber setup in a fresh container"
    if [[ "$mode" == auto ]]; then
        # first --dry-run: it shows the plan and must change nothing at all
        local dry
        dry=$(docker exec -e LABBER_URL=file:///t/labber.tar.gz -e LABBER_REPO=file:///t/repo "$name" \
            bash -c "bash <(cat /t/labber) setup --dry-run --virt lxc --docker no --with nfs,fail2ban \
                --ssh-key '$key' --prometheus http://127.0.0.1:9090 --network skip </dev/null" 2>&1 | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')
        echo "$dry" | grep -E 'dry-run|Prometheus|Loki|SSH key|network|timezone' | head -8
        grep -q 'nothing was changed' <<< "$dry" && grep -q 'http://127.0.0.1:9090  (--prometheus)' <<< "$dry" \
            && grep -q 'skip  (--network)' <<< "$dry" && grep -q -- '--ssh-key) → key-only' <<< "$dry" \
            || { echo "$dry"; echo "FAIL: --dry-run didn't show the plan"; return 1; }
        if docker exec "$name" sh -c 'test -e /var/lib/labber/setup.state || command -v alloy || command -v fail2ban-client || test -e /etc/ssh/sshd_config.d/10-labber.conf'; then
            echo "FAIL: --dry-run changed something"; return 1
        fi
        echo "ok   --dry-run: plan shown, nothing changed"
        # the same LXC as above, but one pasted command: every answer a flag, --yes, no
        # terminal and no input at all
        docker exec -e LABBER_URL=file:///t/labber.tar.gz -e LABBER_REPO=file:///t/repo "$name" \
            bash -c "bash <(cat /t/labber) setup --yes --virt lxc --docker no --with nfs,fail2ban \
                --ssh-key '$key' --prometheus http://127.0.0.1:9090 --network skip </dev/null" 2>&1 \
            | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tee "$tmp/setup-$mode.log" | grep -E '^(::|✓|!|error)' || true
        docker cp "$tmp/setup-$mode.log" "$name:/root/setup1.log"
        echo ":: [$mode] checking the result (the LXC checks)"
        docker exec "$name" bats "/t/setup-lxc.bats"
        return
    fi
    docker exec -e LABBER_URL=file:///t/labber.tar.gz -e LABBER_REPO=file:///t/repo -i "$name" \
        script -qefc 'bash -c "bash <(cat /t/labber) setup"' /dev/null <<< "$answers" \
        | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | tee "$tmp/setup-$mode.log" \
        | grep -E '^(::|✓|!|error)' || true
    docker cp "$tmp/setup-$mode.log" "$name:/root/setup1.log"

    echo ":: [$mode] checking the result"
    docker exec "$name" bats "/t/setup-$mode.bats"
}

rc=0
for m in $modes; do run_mode "$m" || rc=1; done
exit "$rc"
