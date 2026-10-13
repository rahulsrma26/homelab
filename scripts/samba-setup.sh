#!/usr/bin/env bash
# samba-setup.sh — native Samba (SMB) file shares on Debian, e.g. inside an LXC.
#
# Why native and not a container: Samba is a network service with regular security
# fixes. Installed from Debian, those arrive automatically (unattended-upgrades).
#
# What it sets up (hardened defaults):
#   - SMB3 only, encryption whenever the client supports it, port 445 only
#   - no NetBIOS/nmbd, no guest or anonymous access, no printers
#   - one login (a Samba user backed by a no-login system user)
#   - macOS-friendly settings (Finder metadata in extended attributes, odd file names)
#   - shares read-write or read-only; writes are forced to one owner (default root,
#     i.e. the LXC's root in an unprivileged LXC), so other tools on the same folders
#     (e.g. Filebrowser) agree on ownership
#   - optional: only allow given networks (hosts allow)
#
# Usage (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/samba-setup.sh)
#   ... --user alice --share files=/mnt/files --share vault=/mnt/vault:ro
#   flags: --user NAME  --password PW  --share NAME=PATH[:ro] (repeat)  --owner USER
#          --allow "CIDR CIDR …"  --dry-run  --yes
# Re-run any time to change shares: it rewrites smb.conf (old copy kept next to it),
# keeps the password unless --password is given, and checks a real login at the end.
set -euo pipefail

USER_NAME="" PASSWORD="" OWNER="" ALLOW="" DRY=0 YES=0 ALLOW_SET=0
SHARES=()
while (( $# )); do
    case "$1" in
        --user) USER_NAME="${2:-}"; shift ;;
        --password) PASSWORD="${2:-}"; shift ;;
        --share) SHARES+=("${2:-}"); shift ;;
        --owner) OWNER="${2:-}"; shift ;;
        --allow) ALLOW="${2:-}"; ALLOW_SET=1; shift ;;
        --dry-run) DRY=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) echo "usage: samba-setup.sh [--user NAME] [--password PW] [--share NAME=PATH[:ro]]… [--owner USER] [--allow \"CIDR …\"] [--dry-run] [--yes]"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ -t 1 ]]; then R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' C=$'\033[0;36m' B=$'\033[1m' N=$'\033[0m'; else R='' G='' Y='' C='' B='' N=''; fi
info() { echo -e "${C}:: $*${N}"; }
ok()   { echo -e "${G}✓ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
die()  { echo -e "${R}error: $*${N}" >&2; exit 1; }
interactive() { (( ! YES )) && [[ -t 0 ]]; }
# ask <var> <question> [default]
ask() {
    local var="$1" q="$2" def="${3:-}" ans
    [[ -n "${!var}" ]] && return 0
    if ! interactive; then
        [[ -n "$def" ]] || die "$q: no default — pass it as a flag"
        printf -v "$var" '%s' "$def"; return 0
    fi
    read -rp "$q${def:+ [$def]}: " ans || true
    printf -v "$var" '%s' "${ans:-$def}"
}

CONF=/etc/samba/smb.conf

# ── checks and answers ────────────────────────────────────────────────────────
(( EUID == 0 )) || die "run as root (on a sudo machine: sudo -i first)"
command -v apt-get >/dev/null || die "needs a Debian-based system (apt)"
info "Samba setup on $(hostname)"

ask USER_NAME "SMB login name (lowercase letters/digits)"
[[ "$USER_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "login name: lowercase letters, digits, - and _ (start with a letter)"

if (( ${#SHARES[@]} == 0 )); then
    def=""
    for s in files:/mnt/files media:/mnt/media vault:/mnt/vault:ro; do
        p="${s#*:}"; p="${p%:ro}"
        [[ -d "$p" ]] && def+="${s%%:*}=${s#*:} "
    done
    line=""; ask line "Shares (NAME=PATH, add :ro for read-only; space-separated)" "${def% }"
    read -ra SHARES <<< "$line"
fi
(( ${#SHARES[@]} )) || die "no shares given"
for sh in "${SHARES[@]}"; do
    [[ "$sh" =~ ^[A-Za-z0-9_-]+=/[^:]+(:ro)?$ ]] || die "share \"$sh\": expected NAME=/path or NAME=/path:ro"
    p="${sh#*=}"; p="${p%:ro}"
    [[ -d "$p" ]] || die "share \"${sh%%=*}\": $p is not a folder"
done

ask OWNER "Owner of everything written over SMB (a local user)" root
id "$OWNER" >/dev/null 2>&1 || die "owner \"$OWNER\" doesn't exist on this machine"

if (( ! ALLOW_SET )) && interactive; then
    read -rp "Only allow these networks (CIDRs, e.g. your home VLAN and Tailscale 100.64.0.0/10; Enter = any): " ALLOW || true
fi
for c in $ALLOW; do [[ "$c" =~ ^[0-9.]+(/[0-9]{1,2})?$ || "$c" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] || die "--allow: \"$c\" isn't an IP or CIDR"; done

# ── plan ──────────────────────────────────────────────────────────────────────
echo
echo "${B}Plan${N}"
echo "  login    : $USER_NAME (Samba user, backed by a no-login system user)"
for sh in "${SHARES[@]}"; do
    p="${sh#*=}"; mode="read-write (as $OWNER)"; [[ "$p" == *:ro ]] && mode="read-only"
    printf '  share    : %-10s %-28s %s\n' "${sh%%=*}" "${p%:ro}" "$mode"
done
echo "  security : SMB3 only, encryption when supported, port 445, no NetBIOS/guest/anonymous"
echo "  access   : ${ALLOW:-any network}"
echo "  updates  : Debian's samba package (security fixes via unattended-upgrades)"
echo
if (( ! DRY )) && interactive; then
    read -rp "Continue? [y/N] " a || true
    [[ "$a" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
fi

# ── smb.conf ──────────────────────────────────────────────────────────────────
conf=$(
    cat <<EOF
# managed by samba-setup.sh — re-run the script rather than editing
[global]
   server role = standalone server
   server string = %h
   workgroup = WORKGROUP
   # SMB over 445 only: no NetBIOS name service, no port 139
   disable netbios = yes
   smb ports = 445
   server min protocol = SMB3_00
   smb encrypt = desired
   # no guests, no anonymous listing
   map to guest = never
   restrict anonymous = 2
   usershare allow guests = no
   # no printers
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   logging = systemd
   log level = 1
   # macOS: Finder metadata and resource forks in extended attributes, odd file names
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   # no DOS archive flag → no executable bit on every file
   map archive = no
EOF
    if [[ -n "$ALLOW" ]]; then
        echo "   hosts allow = 127.0.0.1 ::1 $ALLOW"
        echo "   hosts deny = ALL"
    fi
    for sh in "${SHARES[@]}"; do
        name="${sh%%=*}"; p="${sh#*=}"
        echo
        echo "[$name]"
        echo "   path = ${p%:ro}"
        echo "   valid users = $USER_NAME"
        echo "   browseable = yes"
        if [[ "$p" == *:ro ]]; then
            echo "   read only = yes"
        else
            echo "   read only = no"
            echo "   force user = $OWNER"
            echo "   force group = $(id -gn "$OWNER")"
        fi
    done
)

if (( DRY )); then
    echo "${B}── $CONF${N}"; echo "$conf"; echo
    info "dry run — nothing was changed"; exit 0
fi

info "installing samba"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q samba smbclient >/dev/null

[[ -f "$CONF" ]] && cp -a "$CONF" "$CONF.bak-$(date +%F-%H%M%S)"
tmp=$(mktemp)
echo "$conf" > "$tmp"
testparm -s "$tmp" >/dev/null 2>&1 || { testparm -s "$tmp" 2>&1 | tail -5; rm -f "$tmp"; die "the generated smb.conf doesn't pass testparm (nothing changed)"; }
install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
ok "smb.conf written (testparm OK)"

# ── the login ─────────────────────────────────────────────────────────────────
if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
    ok "system user $USER_NAME created (no login shell)"
fi
NEWPW=0
if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$USER_NAME"; then
    if [[ -n "$PASSWORD" ]]; then
        printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s "$USER_NAME" >/dev/null
        ok "password for $USER_NAME changed"
    else
        ok "Samba user $USER_NAME exists — password unchanged"
    fi
else
    [[ -n "$PASSWORD" ]] || { PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24); NEWPW=1; }
    printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s -a "$USER_NAME" >/dev/null
    smbpasswd -e "$USER_NAME" >/dev/null
    ok "Samba user $USER_NAME created"
fi

# ── services ──────────────────────────────────────────────────────────────────
systemctl disable --now nmbd.service >/dev/null 2>&1 || true
systemctl enable smbd.service >/dev/null 2>&1
systemctl restart smbd.service
for _ in $(seq 10); do ss -ltnH 'sport = :445' 2>/dev/null | grep -q . && break; sleep 1; done
ss -ltnH 'sport = :445' | grep -q . || die "smbd isn't listening on 445 (journalctl -u smbd -b)"
ok "smbd running on 445 (nmbd off)"

# ── verify a real login (when we know the password) ─────────────────────────
if [[ -n "$PASSWORD" ]]; then
    first="${SHARES[0]%%=*}"
    if smbclient "//127.0.0.1/$first" -U "$USER_NAME%$PASSWORD" -m SMB3 -c 'ls' >/dev/null 2>&1; then
        ok "login works (share $first, SMB3)"
    else
        die "login to //127.0.0.1/$first failed — check: journalctl -u smbd -b"
    fi
fi

echo
ok "done"
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -1)
if (( NEWPW )); then
    warn "new password for $USER_NAME — save it in your password manager now (shown only this once):"
    echo "    $PASSWORD"
fi
echo "  connect (Mac): Finder → Go → Connect to Server → smb://${ip:-<this-ip>}/${SHARES[0]%%=*}"
echo "  firewall     : clients → this machine on 445/tcp"
echo "  logs         : journalctl -u smbd"
