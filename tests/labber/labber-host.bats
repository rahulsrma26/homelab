#!/usr/bin/env bats
# labber-host on a pretend Proxmox host: pct, zfs, pvesm, pve-firewall and systemctl are stubs on
# PATH that log their calls; the firewall files, the state and /etc/pve are a temp folder; the
# forward-only checks use real Git repos signed with a throwaway SSH key. Runs as root (Docker).

setup() {
    LH="${LABBER_HOST:-$BATS_TEST_DIRNAME/../../labber/labber-host}"
    T="$BATS_TEST_TMPDIR"; export T
    mkdir -p "$T/bin" "$T/pve/firewall" "$T/pve/lxc" "$T/state"
    export LABBER_HOST_CONF="$T/labber-host.conf" LABBER_HOST_STATE="$T/state" LABBER_HOST_PVE="$T/pve" \
           LABBER_HOST_FW_WAIT=0 LABBER_HOST_START_WAIT=0 LABBER_HOST_FWCONF="$T/fw.conf"
    printf 'immich 1011 tank/vault/photos\ndocs 1012\n' > "$LABBER_HOST_CONF"
    for id in 1011 1012; do
        printf 'rootfs: tdata:subvol-%s-disk-0,size=8G\nnet0: name=eth0,bridge=vmbr0,firewall=1,ip=192.0.2.%s/24\n' "$id" "${id#10}" > "$T/pct-config-$id"
        printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.6 -p tcp -dport 2283 -log nolog\n' > "$T/pve/firewall/$id.fw"
        touch "$T/pve/lxc/$id.conf"
    done
    echo 'mp0: /tank/vault/photos,mp=/mnt/photos' >> "$T/pct-config-1011"
    printf 'svc\n' > "$T/services"
    echo 'Status: enabled/running' > "$T/pvefw"
    touch "$T/has-sanoid" "$T/sanoid-timer-on"
    cat > "$T/bin/pct" <<'S'
#!/bin/bash
echo "pct $*" >> "$T/calls"
case "$1" in
    config) cat "$T/pct-config-$2" ;;
    exec)   cmd="$6"
            case "$cmd" in
                # what's running: the command itself, run for real against a service folder whose
                # containers are all stopped (docker prints nothing), as in a CT with a stopped service
                *"docker compose ps"*) mkdir -p /opt/homelab/services/svc && touch /opt/homelab/services/svc/docker-compose.yml
                    PATH="$T/nodocker:$PATH" bash -c "$cmd"; exit $? ;;
                *"for d in /opt/homelab/services"*) cat "$T/services" ;;
                *flock*) exit "${FLOCK_RC:-0}" ;;
                *" stop "*) grep -q "labber-host: closed" "$LABBER_HOST_PVE/firewall/$2.fw" && echo "stopped while closed" >> "$T/calls" ;;
            esac ;;
esac
exit 0
S
    cat > "$T/bin/zfs" <<'S'
#!/bin/bash
echo "zfs $*" >> "$T/calls"
last="${*: -1}"
case "$1" in
    list) if [[ "$*" == *"-t snapshot"* ]]; then f="$T/snaps-${last//\//_}"; [[ -f "$f" ]] && cat "$f"
          else echo "${last#/}"; fi ;;
    get)  if [[ "$*" == *mountpoint* ]]; then echo "/$last"; else echo 1M; fi ;;
esac
exit 0
S
    printf '#!/bin/bash\necho "/tank/${2#*:}"\n' > "$T/bin/pvesm"
    printf '#!/bin/bash\ncat "$T/pvefw"\n' > "$T/bin/pve-firewall"
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$T/calls"
case "$1" in
    cat) [[ -f "$T/has-sanoid" ]] ;;
    is-active) [[ "$*" == *sanoid.timer* ]] && { [[ -f "$T/sanoid-timer-on" ]]; exit; }
               [[ "$*" == *sanoid.service* ]] && { [[ -f "$T/sanoid-running" ]]; exit; }
               exit 1 ;;
    stop)  [[ "$2" == sanoid.timer ]] && rm -f "$T/sanoid-timer-on"; exit 0 ;;
    start) [[ "$2" == sanoid.timer ]] && touch "$T/sanoid-timer-on"; exit 0 ;;
esac
S
    mkdir -p "$T/nodocker"; printf '#!/bin/sh\nexit 0\n' > "$T/nodocker/docker"; chmod +x "$T/nodocker/docker"
    chmod +x "$T"/bin/*
    export PATH="$T/bin:$PATH"
    : > "$T/calls"
}

lh() { bash "$LH" --yes "$@"; }
# one assertion per line: bash's set -e ignores a failure inside "a && b" and any "! cmd"
nope() { if "$@"; then echo "unexpectedly true: $*" >&2; return 1; fi; }
closed() { grep -q "labber-host: closed" "$T/pve/firewall/$1.fw"; }

# ── closing: proven before anything stops ──────────────────────────────────────

@test "snap: a NIC without firewall=1 → refused before anything stops" {
    sed -i 's/firewall=1/firewall=0/' "$T/pct-config-1011"
    cp "$T/pve/firewall/1011.fw" "$T/before"
    run lh snap immich
    [ "$status" -ne 0 ]
    [[ "$output" == *"no firewall=1"* ]]
    nope grep -q " stop \|zfs snapshot\|sync hold" "$T/calls"
    cmp -s "$T/before" "$T/pve/firewall/1011.fw"
}

@test "snap: firewall off for the CT, or the host's firewall not running → refused" {
    sed -i 's/^enable: 1/enable: 0/' "$T/pve/firewall/1011.fw"
    run lh snap immich
    [ "$status" -ne 0 ]
    [[ "$output" == *"enable: 1"* ]]
    sed -i 's/^enable: 0/enable: 1/' "$T/pve/firewall/1011.fw"
    echo 'Status: disabled/running' > "$T/pvefw"
    run lh snap immich
    [ "$status" -ne 0 ]
    [[ "$output" == *"host's firewall"* ]]
    nope grep -q "zfs snapshot" "$T/calls"
}

@test "snap: waits for sync, closes (the DROP first), then stops, pauses sanoid, snapshots" {
    run lh snap immich
    [ "$status" -eq 0 ]
    closed 1011
    [ "$(awk '/^\[RULES\]/ {getline; print; exit}' "$T/pve/firewall/1011.fw")" = "IN DROP -log nolog # labber-host: closed for a deployment" ]
    grep -n "sync hold" "$T/calls" | head -1 | grep -q .
    [ "$(grep -n 'sync hold' "$T/calls" | cut -d: -f1)" -lt "$(grep -n 'flock' "$T/calls" | cut -d: -f1)" ]
    grep -q "stopped while closed" "$T/calls"
    [ ! -e "$T/sanoid-timer-on" ]
    [ -e "$T/state/immich.sanoid-paused" ]
    grep -q "zfs snapshot tank/subvol-1011-disk-0@labber-.* tank/vault/photos@labber-" "$T/calls"
}

@test "snap: a sync still running after the wait → nothing stopped, not closed" {
    FLOCK_RC=1 run lh snap immich
    [ "$status" -ne 0 ]
    [[ "$output" == *"still running"* ]]
    nope closed 1011
    nope grep -q " stop \|zfs snapshot" "$T/calls"
}

# ── sanoid: paused per guest ───────────────────────────────────────────────────

@test "open: reopens, releases sync, starts sanoid again once no guest is closed" {
    lh snap immich >/dev/null; lh snap docs >/dev/null
    [ ! -e "$T/sanoid-timer-on" ]
    run lh open immich
    [ "$status" -eq 0 ]
    nope closed 1011
    [[ "$output" == *"sanoid stays paused: docs"* ]]
    [ ! -e "$T/sanoid-timer-on" ]
    run lh open docs
    [ "$status" -eq 0 ]
    [ -e "$T/sanoid-timer-on" ]
    grep -q "sync release" "$T/calls"
}

@test "rollback: a newer snapshot (sanoid's) → stops and says what to do; no -r" {
    lh snap immich >/dev/null
    snap=$(sed -n 's/^snap=//p' "$T/state/immich.snap")
    printf 'tank/vault/photos@%s\ntank/vault/photos@autosnap_2026-11-08_12:00:00_hourly\n' "$snap" > "$T/snaps-tank_vault_photos"
    printf 'tank/subvol-1011-disk-0@%s\n' "$snap" > "$T/snaps-tank_subvol-1011-disk-0"
    : > "$T/calls"
    run lh rollback immich
    [ "$status" -ne 0 ]
    [[ "$output" == *"newer snapshot"* ]]
    nope grep -q "zfs rollback\|pct stop" "$T/calls"
}

@test "rollback: back to the snapshot, still closed, sanoid running again" {
    lh snap immich >/dev/null
    snap=$(sed -n 's/^snap=//p' "$T/state/immich.snap")
    for ds in tank/vault/photos tank/subvol-1011-disk-0; do echo "$ds@$snap" > "$T/snaps-${ds//\//_}"; done
    run lh rollback immich
    [ "$status" -eq 0 ]
    closed 1011
    [ -e "$T/sanoid-timer-on" ]
    grep -q "zfs rollback tank/vault/photos@$snap" "$T/calls"
}

@test "status: warns when sanoid is stopped and no guest is closed" {
    rm -f "$T/sanoid-timer-on"
    run lh status
    [[ "$output" == *"sanoid.timer is stopped and no guest is closed"* ]]
    lh snap immich >/dev/null
    run lh status
    [[ "$output" != *"sanoid.timer is stopped"* ]]
    [[ "$output" == *"immich (CT 1011): CLOSED"* ]]
}

@test "no sanoid on the host (ms01): snap and open don't touch it" {
    rm -f "$T/has-sanoid"
    lh snap immich >/dev/null
    lh open immich >/dev/null
    nope grep -q "systemctl stop\|systemctl start" "$T/calls"
}

# ── firewall files: signed, and only ever forward ──────────────────────────────

fw_repo() {
    ssh-keygen -q -t ed25519 -N '' -f "$T/key"
    git init -qb main "$T/cfg"; git -C "$T/cfg" config uploadpack.allowFilter true
    mkdir -p "$T/cfg/firewall/testhost"
    printf 'repo=file://%s\nforgejo_key=%s\nhost=testhost\n' "$T/cfg" "$(cat "$T/key.pub")" > "$LABBER_HOST_FWCONF"
}
commit() {   # commit <message> [unsigned]: changes 1012.fw
    printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\n# %s\nIN ACCEPT -source 192.0.2.20 -log nolog\n' "$1" > "$T/cfg/firewall/testhost/1012.fw"
    git -C "$T/cfg" add -A
    if [[ "${2:-}" == unsigned ]]; then git -C "$T/cfg" -c user.name=x -c user.email=x@x commit -qm "$1"
    else git -C "$T/cfg" -c user.name=forgejo -c user.email=f@x -c gpg.format=ssh -c user.signingkey="$T/key" commit -S -qm "$1"; fi
}

@test "firewall sync: signed and forward → applied and remembered" {
    fw_repo; commit one
    run lh firewall sync --all
    [ "$status" -eq 0 ]
    grep -q "# one" "$T/pve/firewall/1012.fw"
    commit two
    run lh firewall sync --all
    [ "$status" -eq 0 ]
    grep -q "# two" "$T/pve/firewall/1012.fw"
}

@test "firewall: a rewound main (an older signed commit) → refused" {
    fw_repo; commit one; old=$(git -C "$T/cfg" rev-parse HEAD); commit two
    lh firewall sync --all >/dev/null
    git -C "$T/cfg" reset -q --hard "$old"
    run lh firewall diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"doesn't descend from"* ]]
    run lh firewall sync --all
    [ "$status" -ne 0 ]
    grep -q "# two" "$T/pve/firewall/1012.fw"
}

@test "firewall: an unsigned commit under a signed tip → refused" {
    fw_repo; commit one
    lh firewall sync --all >/dev/null
    commit sneaky unsigned; commit three
    run lh firewall sync --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't signed by Forgejo"* ]]
    grep -q "# one" "$T/pve/firewall/1012.fw"
}

@test "firewall: an unsigned tip → refused, nothing written" {
    fw_repo; commit one unsigned
    run lh firewall sync --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"isn't signed"* ]]
    nope grep -q "# one" "$T/pve/firewall/1012.fw"
}
