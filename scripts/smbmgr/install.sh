#!/usr/bin/env bash
# install.sh — set up native Samba with smbmgr (the share manager) on Debian, e.g. in an LXC.
#
# Installs Debian's samba package (security fixes arrive with unattended-upgrades), writes
# the hardened global config (SMB3 + encryption, port 445 only, no NetBIOS/guests/printers,
# macOS-friendly), and installs `smbmgr` to /usr/local/sbin. Then manage shares with smbmgr:
#   smbmgr add docs /mnt/files/docs     (smbmgr help)
#
# Usage (as root; on a sudo machine: sudo -i first):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/smbmgr/install.sh)
#   flags: --allow "CIDR …" | --any   --owner USER   --yes
#   --uninstall: removes Samba, smbmgr, its state and the users it made; the shared folders stay
# Re-running upgrades smbmgr and keeps every share, user and password. The first run asks
# for the owner and the networks; later runs only change them when given as flags.
set -euo pipefail

REF="${SMBMGR_REF:-main}"     # the repo branch smbmgr is downloaded from (main = passed CI)
URL="https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/$REF/scripts/smbmgr/smbmgr"
ALLOW="" ALLOW_SET=0 OWNER="" YES=0 UNINSTALL=0
while (( $# )); do
    case "$1" in
        --allow) ALLOW="${2:-}"; ALLOW_SET=1; shift ;;
        --any) ALLOW=""; ALLOW_SET=1 ;;
        --owner) OWNER="${2:-}"; shift ;;
        --yes|-y) YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) echo "usage: install.sh [--allow \"CIDR …\" | --any] [--owner USER] [--yes] | --uninstall [--yes]"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ -t 1 ]]; then R=$'\033[0;31m' G=$'\033[0;32m' C=$'\033[0;36m' N=$'\033[0m'; else R='' G='' C='' N=''; fi
info() { echo -e "${C}:: $*${N}"; }
ok()   { echo -e "${G}✓ $*${N}"; }
die()  { echo -e "${R}error: $*${N}" >&2; exit 1; }
interactive() { (( ! YES )) && [[ -t 0 ]]; }

(( EUID == 0 )) || die "run as root (on a sudo machine: sudo -i first)"
command -v apt-get >/dev/null || die "needs a Debian-based system (apt)"
first=1; [[ -f /etc/smbmgr/config ]] && first=0

if (( UNINSTALL )); then
    if (( ! YES )); then
        [[ -t 0 ]] || die "--uninstall without a terminal needs --yes"
        read -rp "Remove Samba, smbmgr, all shares and their users? The shared folders stay. [y/N] " a
        [[ "$a" == [yY]* ]] || die "cancelled — nothing changed"
    fi
    systemctl disable --now smbd.service >/dev/null 2>&1 || true
    # only the accounts smbmgr made (it records them), and only no-login system users
    if [[ -f /etc/smbmgr/accounts ]]; then
        while read -r u; do
            [[ -n "$u" ]] || continue
            IFS=: read -r _ _ uid _ _ _ sh < <(getent passwd "$u") || continue
            (( uid >= 100 && uid < 1000 )) && [[ "$sh" == */nologin ]] || continue
            smbpasswd -x "$u" >/dev/null 2>&1 || true
            userdel "$u" 2>/dev/null || true
        done < /etc/smbmgr/accounts
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -q samba smbclient >/dev/null
    rm -rf /etc/smbmgr /usr/local/sbin/smbmgr /run/smbmgr.lock
    rm -f /etc/samba/smb.conf /etc/samba/smb.conf.bak-*
    ok "Samba and smbmgr removed (the shared folders are untouched; apt autoremove clears leftover libraries)"
    exit 0
fi

info "installing samba"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q samba smbclient >/dev/null
# no NetBIOS: nmbd off for good
systemctl disable --now nmbd.service >/dev/null 2>&1 || true

# smbmgr itself: the copy next to this script (a checkout, tests), else from the repo
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if [[ -n "$here" && -f "$here/smbmgr" ]]; then
    cp "$here/smbmgr" "$tmp"; src="$here/smbmgr"
else
    curl -fsSL "$URL" -o "$tmp" || die "couldn't download smbmgr from $URL"; src="$URL"
fi
if ! bash -n "$tmp" || ! head -1 "$tmp" | grep -q '^#!.*bash'; then die "the downloaded smbmgr isn't a valid script ($src)"; fi
old=$(smbmgr version 2>/dev/null || true)
install -m 755 "$tmp" /usr/local/sbin/smbmgr
new=$(smbmgr version)
if [[ -n "$old" && "$old" != "$new" ]]; then ok "$old → $new"; else ok "$new installed (/usr/local/sbin/smbmgr)"; fi

# first install: ask; later: only what's given as flags
if (( first )); then
    if [[ -z "$OWNER" ]] && interactive; then read -rp "Owner of everything written over SMB [root]: " OWNER || true; fi
    if (( ! ALLOW_SET )) && interactive; then
        read -rp "Only allow these networks (space-separated CIDRs, e.g. your home VLAN; Enter = any): " ALLOW || true; ALLOW_SET=1
    fi
fi
smbmgr apply >/dev/null                                  # creates the state and the global config
# a typo asks again (in a terminal); otherwise stop here, before Samba is enabled
until [[ -z "$OWNER" ]] || smbmgr owner "$OWNER"; do
    interactive || die "fix --owner and run install.sh again"
    read -rp "Owner of everything written over SMB [root]: " OWNER || true
done
if (( ALLOW_SET )); then
    until if [[ -n "$ALLOW" ]]; then smbmgr allow "$ALLOW"; else smbmgr allow --any; fi; do
        interactive || die "fix --allow and run install.sh again"
        read -rp "Only allow these networks (space-separated CIDRs; Enter = any): " ALLOW || true
    done
fi

systemctl enable smbd.service >/dev/null 2>&1
# an upgrade only reloads (smbmgr did): open sessions stay. A restart is needed first time
# (ports change), or when smbd is down or still on 139 (an earlier, interrupted install)
if (( first )) || ! systemctl is-active --quiet smbd.service || [[ -n "$(ss -ltnH 'sport = :139' 2>/dev/null || true)" ]]; then
    systemctl restart smbd.service
fi
for _ in $(seq 10); do ss -ltnH 'sport = :445' 2>/dev/null | grep -q . && break; sleep 1; done
echo
smbmgr check || die "something isn't right (above)"
echo
ok "Samba is ready. Next:"
echo "  smbmgr add <name> <path>          share a folder (users <name>-ro / <name>-rw)"
echo "  smbmgr user add <you> --rw … --ro …   a personal account for Finder"
echo "  smbmgr help"
