#!/usr/bin/env bash
# scripts/nut — set up NUT (Network UPS Tools) on a Proxmox host or any Debian machine
# (e.g. an Orange Pi), so it shuts down cleanly on a power cut and other hosts on the
# same UPS can follow.
#
# Roles (asked at the start, or --role):
#   server   the UPS's USB cable is plugged into this machine. Policies (--policy):
#              lb         shut down at low battery, then cut the UPS output so everything
#                         on it powers back on with mains (also handles mains returning
#                         during the shutdown). For a UPS whose last host is this one.
#              fsd-timer  after N seconds on battery: shut down the clients, then this
#                         host, then cut the UPS output. For a UPS that only powers servers.
#              self-timer after N seconds on battery: shut down only this host. The UPS
#                         keeps running (it also powers the network, an NVR, ...).
#   client   another machine on the SAME UPS, talking to its server over the network:
#              lb         shut down at low battery (or when the server says so)
#              timer      shut down after N seconds on battery
#   monitor  USB attached, but never shuts anything down or cuts the output: only reports
#            the UPS (to clients and Home Assistant). Clients still shut down at low battery.
#
# Every server/monitor gets three users in upsd.users, passwords generated on the first run
# and kept on re-runs: "upsmon" (this host's own monitor), "client" (other hosts on this
# UPS) and "homeassistant" (read-only, for Home Assistant's NUT integration).
#
# Power events (on battery, back online, low battery, shutdown, lost contact, replace
# battery) are logged and mailed to root. On Proxmox, root's mail goes through
# Datacenter → Notifications, so they arrive wherever that sends them (e.g. Telegram).
#
# Usage (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/nut/install.sh)
#   ... --role server --policy lb
#   ... --role client --server <server-ip> --policy timer --timer 180
#   ... --role monitor
#   other flags: --ups <name>  --password <client-password>  --listen <ip>  --dry-run  --yes
#
# Re-running is safe: it rewrites the config (old copy in /etc/nut.bak-<date>) and keeps
# the passwords. Switching a host from server to client (e.g. when the USB cable moves)
# is just a re-run with the new role.
set -euo pipefail

ROLE="" POLICY="" TIMER="" UPS="" SERVER="" CLIENT_PW="" LISTEN="" DRY=0 YES=0
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed '$d; s/^# \{0,1\}//' || true; }
while (( $# )); do
    case "$1" in
        --role) ROLE="${2:-}"; shift ;;
        --policy) POLICY="${2:-}"; shift ;;
        --timer) TIMER="${2:-}"; shift ;;
        --ups) UPS="${2:-}"; shift ;;
        --server) SERVER="${2:-}"; shift ;;
        --password) CLIENT_PW="${2:-}"; shift ;;
        --listen) LISTEN="${2:-}"; shift ;;
        --dry-run) DRY=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) usage; echo "usage: install.sh [--role server|client|monitor] [--policy …] [--timer s] [--ups name] [--server ip] [--password pw] [--listen ip] [--dry-run] [--yes]"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ -t 1 ]]; then R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' C=$'\033[0;36m' B=$'\033[1m' N=$'\033[0m'; else R='' G='' Y='' C='' B='' N=''; fi
info() { echo -e "${C}:: $*${N}"; }
ok()   { echo -e "${G}✓ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
die()  { echo -e "${R}error: $*${N}" >&2; exit 1; }

# ask <var> <question> [default] — keeps a value already given by flag
ask() {
    local var="$1" q="$2" def="${3:-}" ans
    [[ -n "${!var}" ]] && return 0
    if (( YES )) || [[ ! -t 0 ]]; then
        [[ -n "$def" ]] || die "$q: no default — pass it as a flag"
        printf -v "$var" '%s' "$def"; return 0
    fi
    read -rp "$q${def:+ [$def]}: " ans || true
    printf -v "$var" '%s' "${ans:-$def}"
    [[ -n "${!var}" ]] || die "$q: needs an answer"
}
# choose <var> <question> <option>... — numbered menu, the first option is the default
choose() {
    local var="$1" q="$2"; shift 2
    local opts=("$@") i ans
    [[ -n "${!var}" ]] && return 0
    if (( YES )) || [[ ! -t 0 ]]; then printf -v "$var" '%s' "${opts[0]%%|*}"; return 0; fi
    echo "$q"
    for i in "${!opts[@]}"; do printf '  %d) %-11s %s\n' $((i + 1)) "${opts[$i]%%|*}" "${opts[$i]#*|}"; done
    read -rp "choice [1]: " ans || true
    ans="${ans:-1}"
    if [[ ! "$ans" =~ ^[0-9]+$ ]] || (( ans < 1 || ans > ${#opts[@]} )); then die "not a choice: $ans"; fi
    printf -v "$var" '%s' "${opts[$((ans - 1))]%%|*}"
}
genpw() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20; }
# password of [user] in an existing upsd.users (kept on re-runs)
oldpw() { awk -v u="[$1]" '$1 == u {f = 1; next} /^\[/ {f = 0} f && $1 == "password" {print $3; exit}' /etc/nut/upsd.users 2>/dev/null || true; }

# ── checks ────────────────────────────────────────────────────────────────────
(( EUID == 0 )) || die "run as root"
command -v apt-get >/dev/null || die "needs a Debian-based system (apt)"
[[ -d /etc/pve ]] && host_kind="Proxmox host" || host_kind="Debian machine"
info "NUT setup on $(hostname) ($host_kind)"

choose ROLE "Role of this machine:" \
    "server|the UPS's USB cable is plugged in here; shuts down (and maybe the UPS) on a power cut" \
    "client|another machine on the same UPS; follows its server over the network" \
    "monitor|USB plugged in here, but only reports the UPS — never shuts anything down"
case "$ROLE" in
    server) choose POLICY "When should it shut down?" \
        "lb|at low battery, then cut the UPS output (everything restarts with mains)" \
        "fsd-timer|after N s on battery: clients, then this host, then cut the output" \
        "self-timer|after N s on battery: only this host (UPS keeps powering the rest)" ;;
    client) choose POLICY "When should it shut down?" \
        "lb|at low battery (or when the server says so)" \
        "timer|after N s on battery (big loads go first, the battery lasts longer)" ;;
    monitor) POLICY="none" ;;
    *) die "unknown role: $ROLE (server, client or monitor)" ;;
esac
case "$ROLE/$POLICY" in
    server/lb|server/fsd-timer|server/self-timer|client/lb|client/timer|monitor/none) ;;
    *) die "policy $POLICY doesn't fit role $ROLE" ;;
esac
if [[ "$POLICY" == *timer ]]; then
    ask TIMER "Seconds on battery before shutting down" 180
    if [[ ! "$TIMER" =~ ^[0-9]+$ ]] || (( TIMER < 30 )); then die "--timer: whole seconds, at least 30"; fi
fi

# ── the UPS ───────────────────────────────────────────────────────────────────
DRIVER="" PORT="" VID="" PID="" DESC=""
if [[ "$ROLE" == client ]]; then
    ask SERVER "NUT server (IP or name of the machine the UPS's USB is plugged into)"
    if command -v upsc >/dev/null; then
        names=$(upsc -l "$SERVER" 2>/dev/null || true)
        [[ -n "$names" ]] && info "UPS on $SERVER: $(echo "$names" | paste -sd' ' -)"
        ask UPS "UPS name on $SERVER" "$(echo "$names" | head -1)"
    else
        ask UPS "UPS name on $SERVER (as in its ups.conf)" ups
    fi
    if [[ -z "$CLIENT_PW" ]]; then
        (( YES )) || [[ ! -t 0 ]] && die "--password: the server's \"client\" password is required"
        read -rsp "Password of user \"client\" on $SERVER (from its setup / your password manager): " CLIENT_PW; echo
        [[ -n "$CLIENT_PW" ]] || die "needs the password"
    fi
elif [[ "${NUT_SETUP_DUMMY:-}" == 1 ]]; then
    # tests only: a simulated UPS (dummy-ups reads its state from a file) instead of USB
    DRIVER=dummy-ups PORT=dummy.dev DESC="simulated UPS (test)"
    ask UPS "UPS name" ups
else
    if ! command -v nut-scanner >/dev/null; then
        info "installing NUT to look for the UPS"
        (( DRY )) || DEBIAN_FRONTEND=noninteractive apt-get install -y -q nut-server nut-client >/dev/null
        command -v nut-scanner >/dev/null || (( DRY )) || DEBIAN_FRONTEND=noninteractive apt-get install -y -q nut-scanner >/dev/null 2>&1 || true
    fi
    scan=$(nut-scanner -U -q 2>/dev/null || true)
    field() { echo "$scan" | awk -F' = ' -v k="$1" '$1 ~ "^[ \t]*"k"$" {gsub(/"/, "", $2); print $2; exit}'; }
    if [[ -n "$scan" ]]; then
        DRIVER=$(field driver) PORT=$(field port) VID=$(field vendorid) PID=$(field productid)
        DESC="$(field vendor) $(field product)"; DESC="${DESC# }"
        (( $(echo "$scan" | grep -c '^\[') > 1 )) && warn "more than one UPS found — using the first"
    else
        # nut-scanner missing or found nothing: the usual vendors by USB ID
        usb=$(lsusb 2>/dev/null || cat /sys/bus/usb/devices/*/idVendor 2>/dev/null || true)
        for v in 051d 0463 0764; do
            if echo "$usb" | grep -qi "$v"; then DRIVER=usbhid-ups PORT=auto VID=$v; break; fi
        done
    fi
    [[ -n "$DRIVER" ]] || die "no UPS found on USB — is the cable plugged in? (lsusb, nut-scanner -U)"
    case "${VID,,}" in 051d) def=apc ;; 0463) def=eaton ;; 0764) def=cyberpower ;; *) def=ups ;; esac
    info "found: ${DESC:-UPS} (driver $DRIVER${VID:+, USB $VID:$PID})"
    ask UPS "Name for this UPS (clients and Home Assistant use it)" "$def"
fi
[[ "$UPS" =~ ^[A-Za-z0-9_-]+$ ]] || die "UPS name: letters, digits, - and _ only"
[[ "$ROLE" != client ]] && ask LISTEN "Address upsd listens on (0.0.0.0 = all)" 0.0.0.0

# ── passwords (kept from an earlier run) ──────────────────────────────────────
if [[ "$ROLE" != client ]]; then
    PW_UPSMON=$(oldpw upsmon); PW_CLIENT=$(oldpw client); PW_HA=$(oldpw homeassistant); NEWPW=0
    [[ -n "$PW_UPSMON" ]] || { PW_UPSMON=$(genpw); NEWPW=1; }
    [[ -n "$PW_CLIENT" ]] || { PW_CLIENT=$(genpw); NEWPW=1; }
    [[ -n "$PW_HA" ]] || { PW_HA=$(genpw); NEWPW=1; }
fi

# ── plan ──────────────────────────────────────────────────────────────────────
case "$ROLE/$POLICY" in
    server/lb) what="at low battery: tell clients, shut down, then cut the UPS output (restarts with mains)" ;;
    server/fsd-timer) what="after ${TIMER}s on battery: shut down the clients, then this host, then cut the UPS output" ;;
    server/self-timer) what="after ${TIMER}s on battery: shut down only this host; the UPS keeps running" ;;
    client/lb) what="at low battery: shut down this host" ;;
    client/timer) what="after ${TIMER}s on battery: shut down this host" ;;
    monitor/none) what="never shuts anything down; reports the UPS to clients and Home Assistant" ;;
esac
echo
echo "${B}Plan${N}"
echo "  role    : $ROLE$([[ "$POLICY" != none ]] && echo " ($POLICY)")"
echo "  UPS     : $UPS${SERVER:+ on $SERVER}${DESC:+ — $DESC}"
echo "  action  : $what"
[[ "$ROLE" != client ]] && echo "  listens : $LISTEN:3493 (users: $([[ "$ROLE" == server ]] && echo "upsmon, ")client, homeassistant)"
if [[ "$ROLE" == monitor ]]; then
    echo "  alerts  : none from here (no upsmon) — clients and Home Assistant report power events"
    echo "  writes  : /etc/nut/* (old copy in /etc/nut.bak-<date>)"
else
    echo "  alerts  : power events → syslog$([[ -x /usr/sbin/sendmail ]] && echo " + mail to root")$([[ -d /etc/pve ]] && echo " → Proxmox notifications")"
    echo "  writes  : /etc/nut/* (old copy in /etc/nut.bak-<date>), /usr/local/sbin/nut-notify$([[ "$POLICY" == *timer ]] && echo ", nut-upssched-cmd")"
fi
echo
if (( ! DRY && ! YES )); then
    read -rp "Continue? [y/N] " a || true
    [[ "$a" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
fi

# ── write the config ──────────────────────────────────────────────────────────
# put <path> <mode> — content on stdin; dry run prints it instead
put() {
    if (( DRY )); then echo "${B}── $1 ($2)${N}"; sed 's/password = .*/password = <hidden>/; s/\(MONITOR .* \)[^ ]* \(primary\|secondary\)$/\1<password> \2/'; echo
    elif [[ "$1" == /etc/nut/* ]]; then install -m "$2" -o root -g nut /dev/stdin "$1"   # upsd and the drivers run as nut
    else install -m "$2" -o root -g root /dev/stdin "$1"; fi
}

if (( ! DRY )); then
    info "installing packages"
    pkgs=(nut-client); [[ "$ROLE" != client ]] && pkgs+=(nut-server)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" >/dev/null
    [[ -d /etc/nut ]] && cp -a /etc/nut "/etc/nut.bak-$(date +%F-%H%M%S)"
fi

hdr="# managed by homelab scripts/nut ($ROLE${POLICY:+/$POLICY}) — re-run the script rather than editing"

put /etc/nut/nut.conf 640 <<EOF
$hdr
MODE=$([[ "$ROLE" == client ]] && echo netclient || echo netserver)
EOF

if [[ "$ROLE" != client ]]; then
    {
        echo "$hdr"
        echo "maxretry = 3"
        echo
        echo "[$UPS]"
        echo "  driver = $DRIVER"
        echo "  port = $PORT"
        [[ -n "$VID" ]] && echo "  vendorid = $VID"
        [[ -n "$PID" ]] && echo "  productid = $PID"
        [[ -n "$DESC" ]] && echo "  desc = \"$DESC\""
        if [[ "$POLICY" == lb || "$POLICY" == fsd-timer ]] && [[ "$DRIVER" == usbhid-ups ]]; then
            echo "  # after the shutdown: output off in offdelay s, back on ondelay s after mains returns"
            echo "  # (also when mains is already back — that's what restarts the hosts)"
            echo "  offdelay = 20"
            echo "  ondelay = 30"
        fi
    } | put /etc/nut/ups.conf 640
    if [[ "$DRIVER" == dummy-ups ]]; then
        printf 'ups.status: OL\nbattery.charge: 100\nbattery.runtime: 1800\n' | put /etc/nut/dummy.dev 640
    fi
    {
        echo "$hdr"
        # 0.0.0.0 already covers localhost — listing both makes the second bind fail
        if [[ "$LISTEN" == 0.0.0.0 ]]; then echo "LISTEN 0.0.0.0 3493"
        else echo "LISTEN 127.0.0.1 3493"; [[ "$LISTEN" != 127.0.0.1 ]] && echo "LISTEN $LISTEN 3493"; fi
    } | put /etc/nut/upsd.conf 640
    put /etc/nut/upsd.users 640 <<EOF
$hdr
# this host's own upsmon
[upsmon]
  password = $PW_UPSMON
  upsmon primary

# other hosts on this UPS (their upsmon: MONITOR $UPS@<this-host> 1 client <password> secondary)
[client]
  password = $PW_CLIENT
  upsmon secondary

# Home Assistant's NUT integration (read-only: no actions or commands)
[homeassistant]
  password = $PW_HA
EOF
fi

notify_types="ONLINE ONBATT LOWBATT FSD COMMOK COMMBAD SHUTDOWN REPLBATT NOCOMM"
if [[ "$ROLE" != monitor ]]; then
    {
        echo "$hdr"
        echo "# root: the timer actions run shutdown / upsmon -c fsd"
        echo "RUN_AS_USER root"
        if [[ "$ROLE" == server ]]; then
            echo "MONITOR $UPS@localhost 1 upsmon $PW_UPSMON primary"
        else
            echo "MONITOR $UPS@$SERVER 1 client $CLIENT_PW secondary"
        fi
        echo "MINSUPPLIES 1"
        echo 'SHUTDOWNCMD "/sbin/shutdown -h +0"'
        echo "NOTIFYCMD /usr/local/sbin/nut-notify"
        echo "POLLFREQ 5"
        echo "POLLFREQALERT 5"
        echo "HOSTSYNC 15"
        echo "DEADTIME 25"
        echo "FINALDELAY 5"
        if [[ "$POLICY" == lb || "$POLICY" == fsd-timer ]] && [[ "$ROLE" == server ]]; then
            echo "# flag for the last shutdown stage: cut the UPS output (nutshutdown)"
            echo "POWERDOWNFLAG /etc/killpower"
        fi
        for t in $notify_types; do echo "NOTIFYFLAG $t SYSLOG+EXEC"; done
    } | put /etc/nut/upsmon.conf 640

    if [[ "$POLICY" == *timer ]]; then
        put /etc/nut/upssched.conf 640 <<EOF
$hdr
CMDSCRIPT /usr/local/sbin/nut-upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT * START-TIMER onbatt $TIMER
AT ONLINE * CANCEL-TIMER onbatt
EOF
        if [[ "$POLICY" == fsd-timer ]]; then action="/usr/sbin/upsmon -c fsd"; else action="/sbin/shutdown -h +0"; fi
        put /usr/local/sbin/nut-upssched-cmd 755 <<EOF
#!/bin/sh
$hdr
# called by upssched when a timer from /etc/nut/upssched.conf runs out
case "\$1" in
    onbatt)
        logger -t nut "on battery for ${TIMER}s: $action"
        $action ;;
esac
EOF
    fi

    put /usr/local/sbin/nut-notify 755 <<EOF
#!/bin/sh
$hdr
# called by upsmon for every event (NOTIFYFLAG … EXEC): log it, mail root (Proxmox
# forwards root's mail to its notification targets), then hand over to upssched (timers)
msg="\$(hostname): \$*"
logger -t nut "\$NOTIFYTYPE: \$*"
if [ -x /usr/sbin/sendmail ]; then
    printf 'Subject: UPS %s on %s\n\n%s\n' "\$NOTIFYTYPE" "\$(hostname)" "\$msg" | /usr/sbin/sendmail root 2>/dev/null || true
fi
$([[ "$POLICY" == *timer ]] && echo 'exec /usr/sbin/upssched' || echo 'exit 0')
EOF
fi

if (( DRY )); then info "dry run — nothing was changed"; exit 0; fi

# ── services ──────────────────────────────────────────────────────────────────
info "starting NUT"
if [[ "$ROLE" == client ]]; then
    # e.g. a former server whose USB cable moved elsewhere
    systemctl disable --now nut-server.service nut-driver.target nut-driver-enumerator.path >/dev/null 2>&1 || true
else
    [[ "$DRIVER" == usbhid-ups ]] && { udevadm control --reload; udevadm trigger --subsystem-match=usb --action=add; sleep 2; }
    systemctl enable nut-driver-enumerator.path nut-driver.target nut-server.service >/dev/null 2>&1 || true
    systemctl restart nut-driver-enumerator.service >/dev/null 2>&1 || true
    systemctl restart nut-driver.target >/dev/null 2>&1 || upsdrvctl start >/dev/null 2>&1 || true
    systemctl restart nut-server.service
fi
if [[ "$ROLE" == monitor ]]; then
    systemctl disable --now nut-monitor.service >/dev/null 2>&1 || true
else
    systemctl enable nut-monitor.service >/dev/null 2>&1
    systemctl restart nut-monitor.service
fi
start=$(date +%s)

# ── verify ────────────────────────────────────────────────────────────────────
target="$UPS@$([[ "$ROLE" == client ]] && echo "$SERVER" || echo localhost)"
status=""
# "WAIT" = upsd is up but the driver hasn't delivered data yet
for _ in $(seq 30); do status=$(upsc "$target" ups.status 2>/dev/null || true); [[ -n "$status" && "$status" != WAIT ]] && break; sleep 1; done
[[ -n "$status" && "$status" != WAIT ]] || die "no answer from $target — check: journalctl -u 'nut-*' -b; upsc $target"
ok "UPS $target answers: status $status, battery $(upsc "$target" battery.charge 2>/dev/null || echo ?)%"
if [[ "$ROLE" != client && "$LISTEN" != 127.0.0.1 ]]; then
    # local address column of ss: the chosen IP, or a wildcard (0.0.0.0 / *)
    ss -Hltn 'sport = :3493' 2>/dev/null | awk '{print $4}' | grep -qE "^(${LISTEN//./\\.}|0\.0\.0\.0|\*):3493$" \
        || die "upsd isn't listening on $LISTEN:3493 — clients can't reach it (journalctl -u nut-server -b)"
fi
if [[ "$ROLE" != monitor ]]; then
    sleep 3
    if journalctl -u nut-monitor --since "@$start" --no-pager 2>/dev/null | grep -qiE "login on ups .*failed|ACCESS-DENIED|PASSWORD-REQUIRED|USERNAME-REQUIRED"; then
        die "upsmon couldn't log in to $target — wrong password? (journalctl -u nut-monitor -b)"
    fi
    systemctl is-active --quiet nut-monitor.service || die "nut-monitor isn't running (journalctl -u nut-monitor -b)"
    ok "upsmon is watching $target"
fi
if [[ "$ROLE" == server && "$POLICY" != self-timer ]]; then
    ls /usr/lib/systemd/system-shutdown/nutshutdown /lib/systemd/system-shutdown/nutshutdown >/dev/null 2>&1 \
        || warn "no nutshutdown hook found — the UPS output may not be cut at the end of a shutdown"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
ok "done: $ROLE$([[ "$POLICY" != none ]] && echo " ($POLICY)") — $what"
if [[ "$ROLE" != client ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -1)
    if (( NEWPW )); then
        echo
        warn "new passwords — save them in your password manager now (they stay in /etc/nut/upsd.users):"
        echo "    client         $PW_CLIENT"
        echo "    homeassistant  $PW_HA"
    else
        echo "  passwords unchanged (see /etc/nut/upsd.users)"
    fi
    echo
    echo "  clients on this UPS:  scripts/nut/install.sh --role client --server ${ip:-<this-ip>} --ups $UPS"
    echo "  Home Assistant:       NUT integration → host ${ip:-<this-ip>}, port 3493, user homeassistant"
fi
echo "  check:                upsc $target; journalctl -t nut -b"
