#!/usr/bin/env bash
# Run `labber setup` from scratch in a fresh Debian container with systemd — the LXC
# path, the way it runs on a new Proxmox LXC: piped (`bash <(curl …) setup`), as root,
# answering every question. Then setup.bats checks the result, including that a second
# run finds nothing left to do. Tests the working tree; needs only Docker (and internet:
# setup installs packages, Alloy and zsh plugins). Takes a few minutes.
#
# Not covered here (they need a real VM, see run-vm.sh): the VM-only steps (admin user,
# time sync, swap, guest agent), Docker, and static IPs.
set -euo pipefail
# macOS tar would add ._* metadata files to every archive
export COPYFILE_DISABLE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
name="labber-setup-test-$$"
image=labber-setup-test

# what setup downloads, from the working tree: labber's tarball (LABBER_URL) and a
# git snapshot of the repo (LABBER_REPO, for tools/: fzf and the p10k config)
tmp=$(mktemp -d)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/t/repo" "$tmp/bundle/homelab-main"
cp -R "$repo/labber" "$tmp/bundle/homelab-main/labber"
tar -czf "$tmp/t/labber.tar.gz" -C "$tmp/bundle" homelab-main
(cd "$repo" && git ls-files -co --exclude-standard -- tools | tar -cf - -T -) | tar -xf - -C "$tmp/t/repo"
(cd "$tmp/t/repo" && git init -q && git config uploadpack.allowFilter true && git add -A \
    && git -c user.name=t -c user.email=t@localhost commit -qm snapshot)
cp "$repo/labber/labber" "$here/setup.bats" "$tmp/t/"

docker build -q -t "$image" "$here/setup" >/dev/null
docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
# copied in and handed to root, as on a real machine: git won't clone a repo that
# belongs to another user, and both a bind mount and docker cp keep the host's user id
docker cp "$tmp/t" "$name:/t"
docker exec "$name" chown -R root:root /t
for _ in $(seq 30); do
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
done

env_args=(-e LABBER_URL=file:///t/labber.tar.gz -e LABBER_REPO=file:///t/repo)
key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl labber-setup-test"
# answers, in order: treat it as a VM? n (→ LXC) · Docker services? n · checklist: a (all), Enter (run)
#   locale: Enter (en_US.UTF-8) · timezone, hostname: Enter · SSH key: paste · logged in? y
#   Prometheus URL · Loki URL: Enter · network: 3 (skip)
answers=$'n\nn\na\n\n'$'\n'$'\n\n'"$key"$'\ny\n'$'http://127.0.0.1:9090\n\n'$'3\n'
echo ":: labber setup in a fresh container (a few minutes)"
docker exec "${env_args[@]}" -i "$name" script -qefc 'bash -c "bash <(cat /t/labber) setup"' /dev/null \
    <<< "$answers" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | tee "$tmp/setup.log" \
    | grep -E '^(::|✓|!|error)' || true
docker cp "$tmp/setup.log" "$name:/root/setup1.log"

echo ":: checking the result"
docker exec "${env_args[@]}" "$name" bats /t/setup.bats
