#!/usr/bin/env bash
# push-tokens.sh: give this Proxmox host and its LXCs their tokens for monitoring's push-gate.
# Run as root on a Proxmox host; it asks (hidden) for the hosts' token, then the guests' token;
# Enter skips that part:
#   bash <(curl -fsSL <raw base URL>/services/monitoring/utils/push-tokens.sh) [--from <raw base URL>] [--dry-run]
# Host: install-exporters.sh again, with the URLs its Alloy uses now (and --igpu if it has that).
# LXCs: each running one with labber and Alloy (monitoring's own too: its Alloy pushes through the
# push-gate like any other): labber update, then labber setup
# --push-token-file with every other step unticked (only Alloy's config changes). VMs: listed at the end, to do by hand.
# --from: where install-exporters.sh comes from (the repo's raw files; default GitHub's main).
set -euo pipefail

FROM="https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main"
DRY=0
usage() { echo "usage: push-tokens.sh [--from <raw base URL>] [--dry-run]"; }
while (( $# )); do
    case "$1" in
        --dry-run|-n) DRY=1; shift ;;
        --from) FROM="${2:?--from needs a URL}"; FROM="${FROM%/}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
die() { echo "push-tokens: $*" >&2; exit 1; }
(( EUID == 0 )) || die "run as root"
command -v pct >/dev/null || die "not a Proxmox host (no pct)"
[[ -r /dev/tty ]] || die "needs a terminal for the tokens"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TOKEN_RE='^[A-Za-z0-9._~+/=-]{32,}$'

# ask <prompt>: a token, typed or pasted without echo; empty: skip
ask() {
    local t
    while :; do
        read -rsp "$1 (Enter skips): " t </dev/tty; echo >&2
        t=$(tr -d '[:space:]' <<<"$t")
        [[ -z "$t" || "$t" =~ $TOKEN_RE ]] && { printf '%s' "$t"; return; }
        echo "  not a token (32+ characters, no spaces); again" >&2
    done
}

# base URLs (…:9090, …:3100) of the Prometheus and Loki an Alloy config pushes to
prom_of() { grep -oE 'url *= *"[^"]*/api/v1/write"' "$1" | head -1 | sed -E 's#.*"(.*)/api/v1/write"#\1#'; }
loki_of() { grep -oE 'url *= *"[^"]*/loki/api/v1/push"' "$1" | head -1 | sed -E 's#.*"(.*)/loki/api/v1/push"#\1#'; }

# ── the host ────────────────────────────────────────────────────────────────────
HT=$(ask "Token for this HOST (PUSH_TOKEN_HOSTS)")
if [[ -n "$HT" ]]; then
    cfg=/etc/alloy/config.alloy
    [[ -f "$cfg" ]] || die "no $cfg here: install-exporters.sh never ran on this host"
    prom=$(prom_of "$cfg"); loki=$(loki_of "$cfg")
    [[ -n "$prom" && -n "$loki" ]] || die "$cfg names no Prometheus/Loki to push to"
    igpu=(); systemctl is-enabled -q igpu-metrics.service 2>/dev/null && igpu=(--igpu)
    echo ":: host: install-exporters.sh $prom $loki ${igpu[*]} --push-token-file <token>"
    if (( ! DRY )); then
        cp -p "$cfg" "/root/config.alloy.before-push-token"     # install-exporters.sh rewrites it
        ( umask 077; printf '%s\n' "$HT" > "$TMP/host-token" )
        curl -fsSL "$FROM/services/monitoring/utils/install-exporters.sh" -o "$TMP/install-exporters.sh" \
            || die "can't fetch install-exporters.sh from $FROM"
        if bash "$TMP/install-exporters.sh" "$prom" "$loki" "${igpu[@]}" --push-token-file "$TMP/host-token" \
                > "$TMP/host.log" 2>&1; then
            echo "  ✓ host (its old config: /root/config.alloy.before-push-token)"
        else
            cp "$TMP/host.log" /root/push-tokens-host.log
            echo "  ✗ host: install-exporters.sh failed (log: /root/push-tokens-host.log)"
        fi
        rm -f "$TMP/host-token"
    fi
fi
unset HT

# ── the LXCs ────────────────────────────────────────────────────────────────────
# prints why a guest is left alone, nothing if it takes the token (both run inside the guest)
# shellcheck disable=SC2016
PROBE='export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
command -v labber >/dev/null || { echo "no labber"; exit 0; }
[ -f /etc/alloy/config.alloy ] || { echo "no Alloy"; exit 0; }
exit 0'
# shellcheck disable=SC2016
APPLY='export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
rc=0
labber update </dev/null || rc=$?
if [ "$rc" -eq 0 ] && ! labber help 2>&1 | grep -q -- --push-token-file; then
    v=$(grep -m1 "^VERSION=" "$(command -v labber)" | cut -d\" -f2)
    echo "labber $v has no --push-token-file: it follows an old source (labber source show; labber source set …)"; rc=3
fi
# only the Alloy step: --yes runs every ticked step (the system update is always ticked)
if [ "$rc" -eq 0 ]; then
    others=$(sed -n "s/^SETUP_STEPS=(\(.*\)).*/\1/p" "$(readlink -f "$(command -v labber)")" | head -n 1 | tr " " "\n" | grep -vx alloy | paste -sd, -)
    if [ -z "$others" ]; then echo "cannot read the setup steps of labber"; rc=4
    else
        # Alloy URLs from its config as it is (labber remembers them only since 2026-10)
        prom=$(grep -oE "url *= *\"[^\"]*/api/v1/write\"" /etc/alloy/config.alloy | head -n 1 | sed -E "s#.*\"(.*)/api/v1/write\"#\1#")
        loki=$(grep -oE "url *= *\"[^\"]*/loki/api/v1/push\"" /etc/alloy/config.alloy | head -n 1 | sed -E "s#.*\"(.*)/loki/api/v1/push\"#\1#")
        if [ -z "$prom" ] || [ -z "$loki" ]; then echo "no Prometheus/Loki URL in /etc/alloy/config.alloy"; rc=5
        else labber setup --push-token-file /root/.push-token --yes --without "$others" \
                --prometheus "$prom" --loki "$loki" </dev/null || rc=$?; fi
    fi
fi
# done means: the token in the Alloy config on both endpoints, and Alloy running
if [ "$rc" -eq 0 ]; then
    n=$(grep -c "bearer_token_file" /etc/alloy/config.alloy 2>/dev/null || true)
    if [ "${n:-0}" -lt 2 ] || [ ! -s /etc/alloy/push-token ]; then echo "setup ran, but the token is not in the Alloy config"; rc=6
    elif ! systemctl is-active -q alloy; then echo "Alloy is not running after the change: journalctl -u alloy"; rc=7; fi
fi
rm -f /root/.push-token
exit "$rc"'

GT=$(ask "Token for the GUESTS (PUSH_TOKEN_GUESTS)")
ok=(); failed=(); skipped=()
if [[ -n "$GT" ]]; then
    for id in $(pct list | awk 'NR > 1 && $2 == "running" {print $1}'); do
        name=$(pct config "$id" | awk '/^hostname:/ {print $2}')
        why=$(pct exec "$id" -- sh -c "$PROBE" 2>/dev/null) || why="can't run commands in it"
        if [[ -n "$why" ]]; then skipped+=("$id $name ($why)"); echo "-- $id $name: skipped ($why)"; continue; fi
        echo ":: $id $name: labber update, then labber setup --push-token-file"
        (( DRY )) && continue
        if pct exec "$id" -- sh -c 'umask 077; cat > /root/.push-token' <<<"$GT" \
                && pct exec "$id" -- sh -c "$APPLY" > "$TMP/$id.log" 2>&1; then
            ok+=("$id $name"); echo "  ✓ $id $name"
        else
            pct exec "$id" -- rm -f /root/.push-token 2>/dev/null || true
            cp "$TMP/$id.log" "/root/push-tokens-$id.log"
            failed+=("$id $name"); echo "  ✗ $id $name (log: /root/push-tokens-$id.log; last lines:)"
            tail -n 3 "/root/push-tokens-$id.log" | sed 's/^/      /'
        fi
    done
fi
unset GT

vms=$(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" {print "  " $1 " " $2}')
echo
(( ${#ok[@]} )) && echo "done: ${#ok[@]} LXC(s)"
(( ${#failed[@]} )) && printf 'failed (see their logs): %s\n' "${failed[@]}"
if [[ -n "$vms" ]]; then
    echo "VMs (by hand, in each: labber update, then labber setup --without update --with pushtoken; untick the rest; its group's token):"
    echo "$vms"
fi
(( ${#failed[@]} == 0 ))
