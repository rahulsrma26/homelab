#!/usr/bin/env bats
# labber-host on a real Proxmox host (pve-ci, rolled back before every run; tests/pve/run.sh): a
# real CT, its real firewall (pve-firewall), real ZFS snapshots and sanoid.timer. Inside the CT
# labber is a stand-in that records what it's told (the subject here is labber-host). The
# closing is checked from outside: the CT's port answers before, not while closed, again after.

NET="${PVE_CI_NET:?set by tests/pve/run.sh: the test bridge /24 prefix, e.g. 192.0.2}"
CT=1101; IP=$NET.101; DS=cipool/owned

lh() { bash /root/repo/labber/labber-host --yes "$@"; }
answers() { timeout 4 bash -c "echo > /dev/tcp/$IP/8080" 2>/dev/null; }   # the CT's port, from the host
nope() { if "$@"; then echo "unexpectedly true: $*" >&2; return 1; fi; }
fw_up() {   # the host's firewall on (SSH stays open), and running
    printf '[OPTIONS]\nenable: %s\n\n[RULES]\nIN ACCEPT -p tcp -dport 22 -log nolog\n' "$1" > /etc/pve/firewall/cluster.fw
    pve-firewall restart >/dev/null 2>&1 || true
    for _ in $(seq 30); do pve-firewall status | grep -q "$([[ $1 == 1 ]] && echo enabled || echo disabled)/running" && return 0; sleep 1; done
    return 1
}

setup_file() {
    export LABBER_HOST_CONF="$BATS_FILE_TMPDIR/labber-host.conf" LABBER_HOST_STATE="$BATS_FILE_TMPDIR/state" LABBER_HOST_START_WAIT=5
    fw_up 1
    zfs create -o mountpoint=/cipool/owned "$DS"
    pct create "$CT" local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst --hostname web --storage cipool --rootfs cipool:2 \
        --memory 512 --unprivileged 0 --features nesting=1 --mp0 /cipool/owned,mp=/mnt/owned \
        --net0 name=eth0,bridge=vmbr1,ip=$IP/24,gw=$NET.1,firewall=1 >/dev/null
    printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -p tcp -dport 8080 -log nolog\n' > "/etc/pve/firewall/$CT.fw"
    pct start "$CT"; sleep 5
    # labber's stand-in (records its arguments), a service folder, something answering on 8080
    pct exec "$CT" -- bash -c 'printf "#!/bin/sh\necho \"\$*\" >> /root/labber-calls\n" > /usr/local/bin/labber && chmod +x /usr/local/bin/labber
        mkdir -p /opt/homelab/services/web && touch /opt/homelab/services/web/docker-compose.yml
        command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3-minimal >/dev/null; }
        systemd-run --unit=web8080 python3 -m http.server 8080 >/dev/null'
    printf 'web %s %s\n' "$CT" "$DS" > "$LABBER_HOST_CONF"
    mkdir -p /etc/sanoid
    printf '[%s]\nuse_template = t\n[template_t]\nhourly = 2\nautosnap = yes\nautoprune = yes\n' "$DS" > /etc/sanoid/sanoid.conf
    systemctl enable --now sanoid.timer >/dev/null 2>&1
    for _ in $(seq 20); do answers && break; sleep 1; done
}
teardown_file() {
    [[ "${KEEP:-0}" == 1 ]] && return 0                                    # left to look at (run.sh KEEP=1)
    pct stop "$CT" >/dev/null 2>&1 || true; pct destroy "$CT" --purge >/dev/null 2>&1 || true
    zfs destroy -r "$DS" >/dev/null 2>&1 || true; rm -f /etc/pve/firewall/cluster.fw
}

@test "before: the CT answers on 8080 through its firewall" {
    answers
}

@test "snap refused when a NIC has no firewall=1: nothing stopped, nothing closed" {
    pct set "$CT" --net0 name=eth0,bridge=vmbr1,ip=$IP/24,gw=$NET.1,firewall=0
    run lh snap web
    pct set "$CT" --net0 name=eth0,bridge=vmbr1,ip=$IP/24,gw=$NET.1,firewall=1
    [ "$status" -ne 0 ]; [[ "$output" == *"no firewall=1"* ]]
    nope grep -q 'labber-host: closed' "/etc/pve/firewall/$CT.fw"
    [ "$(pct status "$CT")" = "status: running" ]
    nope pct exec "$CT" -- test -e /root/labber-calls
    for _ in $(seq 20); do answers && break; sleep 1; done; answers
}

@test "snap refused when the host's firewall is off" {
    fw_up 0
    run lh snap web
    fw_up 1
    [ "$status" -ne 0 ]; [[ "$output" == *"firewall isn't enabled and running"* ]]
    nope grep -q 'labber-host: closed' "/etc/pve/firewall/$CT.fw"
}

@test "snap: closed for real (the port stops answering), services stopped, sanoid paused, both datasets snapshotted" {
    run lh snap web
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(awk '/^\[RULES\]/ {getline; print; exit}' "/etc/pve/firewall/$CT.fw")" = "IN DROP -log nolog # labber-host: closed for a deployment" ]
    nope answers                                                          # Proxmox applied the DROP
    pct exec "$CT" -- grep -qx 'web stop' /root/labber-calls
    pct exec "$CT" -- grep -qx 'web maintenance on' /root/labber-calls
    nope systemctl is-active -q sanoid.timer
    snap=$(awk -F= '/^snap=/ {print $2}' "$LABBER_HOST_STATE/web.snap")
    zfs list -H -o name "$DS@$snap"
    zfs list -H -o name "cipool/subvol-$CT-disk-0@$snap"
}

@test "rollback: what was written after the snap is gone; still closed; sanoid running again" {
    pct exec "$CT" -- bash -c 'echo after > /root/after-snap; echo after > /mnt/owned/after-snap'
    run lh rollback web
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    nope pct exec "$CT" -- test -e /root/after-snap
    nope test -e /cipool/owned/after-snap
    grep -q 'labber-host: closed' "/etc/pve/firewall/$CT.fw"
    nope answers
    systemctl is-active -q sanoid.timer
}

@test "open: answers again; labber told maintenance off and sync released" {
    pct exec "$CT" -- bash -c 'systemctl is-active -q web8080 || systemd-run --unit=web8080 python3 -m http.server 8080 >/dev/null'
    run lh open web
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    nope grep -q 'labber-host: closed' "/etc/pve/firewall/$CT.fw"
    for _ in $(seq 20); do answers && break; sleep 1; done; answers
    pct exec "$CT" -- grep -qx 'web maintenance off' /root/labber-calls
    pct exec "$CT" -- grep -qx 'sync release' /root/labber-calls
    systemctl is-active -q sanoid.timer
}

@test "rollback refused when a newer snapshot (sanoid's) sits on top: nothing touched" {
    lh snap web >/dev/null
    zfs snapshot "$DS@autosnap_newer"
    pct exec "$CT" -- bash -c 'echo kept > /root/kept'
    run lh rollback web
    [ "$status" -ne 0 ]; [[ "$output" == *"has a newer snapshot"* ]]
    pct exec "$CT" -- test -e /root/kept                                  # no rollback happened
    zfs list -H -o name "$DS@autosnap_newer"                              # and nothing destroyed
    lh open web >/dev/null
}
