#!/usr/bin/env bash
# scripts/proxmox-grub-boot — switch a Proxmox VE install (ZFS root, UEFI) from systemd-boot
# to GRUB on all of its boot partitions (ESPs), and keep it that way across updates.
#
# Why: systemd-boot rewrites loader/random-seed on the ESP at every start and flushes it.
# Some firmware NVMe drivers hang on that write (seen on an ODROID-H4 Ultra, BIOS 1.12,
# with Samsung PM983 drives): "Failed to flush random seed file: Time out" followed by
# "Error opening root path: Time out" — and no boot. A normal GRUB boot writes nothing.
#
# What it does:
#   1. checks: root, Proxmox, UEFI, ESPs managed by proxmox-boot-tool, pool health
#   2. converts every systemd-boot ESP to GRUB (the one not currently booted first):
#      format → wait for udev → `proxmox-boot-tool init <esp> grub` → verify → clean
#   3. checks each ESP's grub.cfg: ZFS root on every kernel line, no boot-time writes
#      (no recordfail / savedefault calls, empty grubenv), kernel + initrd present
#   4. removes the dead systemd-boot firmware entries
#   5. installs pbt-grub-sync + an apt hook: after every package run, if a GRUB package
#      changed, it runs `proxmox-boot-tool reinit` and restores the firmware boot order
#      (kernel updates are synced to the ESPs by Proxmox itself)
# Already on GRUB? Then only step 5 runs — safe to re-run any time.
#
# Usage (as root on the Proxmox host):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/proxmox-grub-boot/install.sh)
#   ... --dry-run   show what would happen, change nothing
#   ... --yes       don't ask before changing things
#
# Afterwards: reboot and check `cat /proc/cmdline` starts with BOOT_IMAGE= (GRUB).
# Rules once on GRUB:
#   - never `proxmox-boot-tool kernel pin --next-boot` or `grub-reboot` (GRUB then writes
#     at the next boot); a permanent pin or the GRUB menu is fine
#   - a new/replaced boot disk: `proxmox-boot-tool format <esp> --force`, `udevadm settle`,
#     `proxmox-boot-tool init <esp> grub` (WITH grub), `proxmox-boot-tool clean`,
#     then `pbt-grub-sync --force`
set -euo pipefail

DRY=0 YES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) echo "usage: install.sh [--dry-run] [--yes] — switch Proxmox ESPs to GRUB + install the pbt-grub-sync apt hook (details: top of the script)"; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' C=$'\033[0;36m' N=$'\033[0m'; else R='' G='' Y='' C='' N=''; fi
info() { echo -e "${C}:: $*${N}"; }
ok()   { echo -e "${G}✓ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
die()  { echo -e "${R}error: $*${N}" >&2; exit 1; }
run()  { if (( DRY )); then echo "   [dry-run] $*"; else "$@"; fi; }

PBT=proxmox-boot-tool
UUIDS=/etc/kernel/proxmox-boot-uuids

# ── 1. checks ─────────────────────────────────────────────────────────────────
(( EUID == 0 )) || die "run as root"
command -v "$PBT" >/dev/null || die "$PBT not found — is this a Proxmox VE host?"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode — this is for UEFI installs"
[[ -s $UUIDS ]] || die "no ESPs in $UUIDS — proxmox-boot-tool doesn't manage this system's boot"
dpkg-query -W -f='${Status}' grub-efi-amd64 2>/dev/null | grep -q 'install ok installed' \
    || die "grub-efi-amd64 isn't installed (apt install grub-efi-amd64)"
command -v efibootmgr >/dev/null || die "efibootmgr not found"

status=$("$PBT" status 2>&1)    # proxmox-boot-tool prints its status to stderr
echo "$status" | grep -E 'configured with' || true
zpool status -x 2>/dev/null | grep -q 'all pools are healthy' \
    || warn "a ZFS pool isn't healthy (zpool status) — fix that first if it's rpool"

# the ESP the firmware booted from (BootCurrent → its GPT partition GUID)
cur=$(efibootmgr | sed -nE 's/^BootCurrent: //p')
booted_partuuid=$(efibootmgr -v | grep -E "^Boot${cur}" | grep -oiE 'GPT,[0-9a-f-]{36}' | cut -d, -f2 | tr 'A-F' 'a-f' || true)

# ESPs still on systemd-boot, not-booted ones first
todo=()
booted_dev=""
while read -r uuid; do
    [[ -n "$uuid" ]] || continue
    dev=$(readlink -f "/dev/disk/by-uuid/$uuid" 2>/dev/null || true)
    if [[ ! -b "$dev" ]]; then warn "ESP $uuid in $UUIDS doesn't exist — will be cleaned"; continue; fi
    if echo "$status" | grep -q "^$uuid is configured with: grub"; then continue; fi
    if [[ "$(lsblk -no PARTUUID "$dev")" == "$booted_partuuid" ]]; then booted_dev=$dev; else todo+=("$dev"); fi
done < "$UUIDS"
[[ -n "$booted_dev" ]] && todo+=("$booted_dev")

echo
if (( ${#todo[@]} )); then
    info "ESPs to convert to GRUB (in this order): ${todo[*]}"
    [[ -n "$booted_dev" ]] && info "  ($booted_dev is the one booted now — converted last)"
else
    ok "all ESPs already use GRUB — only the update hook will be installed/refreshed"
fi
if (( ! DRY && ! YES )); then
    read -rp "Continue? [y/N] " ans || true
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
fi
if (( ! DRY )); then
    efibootmgr -v > "/root/efibootmgr-before-grub-$(date +%F-%H%M%S).txt"
fi

# ── 2. + 3. convert and verify each ESP ───────────────────────────────────────
verify_esp() {    # <fs-uuid> — read-only checks of a GRUB ESP
    local uuid="$1" mp c bad=0
    mp=$(mktemp -d)
    mount -o ro "/dev/disk/by-uuid/$uuid" "$mp"
    c="$mp/grub/grub.cfg"
    [[ -f "$mp/EFI/proxmox/grubx64.efi" ]] || { warn "$uuid: EFI/proxmox/grubx64.efi missing"; bad=1; }
    [[ -f "$c" ]] || { warn "$uuid: grub/grub.cfg missing"; bad=1; }
    if [[ -f "$c" ]]; then
        local nlinux nroot
        nlinux=$(grep -cE '^\s*linux\s+/vmlinuz' "$c" || true)
        nroot=$(grep -cE '^\s*linux\s+/vmlinuz.*root=ZFS=[^ ]+/ROOT/[^ ]+ boot=zfs' "$c" || true)
        (( nlinux > 0 && nlinux == nroot )) || { warn "$uuid: not every kernel line has root=ZFS=<pool>/ROOT/… boot=zfs ($nroot of $nlinux)"; bad=1; }
        ! grep -qE '^\s*recordfail\s*$' "$c" || { warn "$uuid: grub.cfg calls recordfail (writes at boot)"; bad=1; }
        ! grep -qE '^\s*savedefault\s*$' "$c" || { warn "$uuid: grub.cfg calls savedefault (writes at boot)"; bad=1; }
    fi
    if [[ -f "$mp/grub/grubenv" ]] && grep -qv '^#' "$mp/grub/grubenv"; then
        warn "$uuid: grubenv isn't empty (a pending one-time boot would make GRUB write)"; bad=1
    fi
    ls "$mp"/vmlinuz-* >/dev/null 2>&1 && ls "$mp"/initrd.img-* >/dev/null 2>&1 || { warn "$uuid: no kernel/initrd on the ESP"; bad=1; }
    [[ ! -d "$mp/loader" ]] || { warn "$uuid: systemd-boot's loader/ still present"; bad=1; }
    umount "$mp"; rmdir "$mp"
    (( bad == 0 )) && ok "$uuid: GRUB config verified (ZFS root, no boot-time writes, kernel present)"
    return "$bad"
}

for dev in ${todo[@]+"${todo[@]}"}; do
    echo; info "converting $dev to GRUB"
    run "$PBT" format "$dev" --force
    if (( ! DRY )); then
        udevadm settle; sleep 2    # without this, init reads the old FS UUID and the ESP isn't registered
        newuuid=$(lsblk -no UUID "$dev")
        [[ -n "$newuuid" ]] || die "$dev has no filesystem UUID after formatting"
    fi
    run "$PBT" init "$dev" grub
    if (( ! DRY )); then
        "$PBT" status 2>&1 | grep -q "^$newuuid is configured with: grub" \
            || die "$dev ($newuuid) isn't registered as a GRUB ESP — check '$PBT status'; the other ESPs are untouched"
        verify_esp "$newuuid" || die "verification of $dev failed — fix before rebooting (the other ESPs still boot)"
    fi
done
run "$PBT" clean

# ── 4. dead systemd-boot firmware entries ─────────────────────────────────────
if (( ! DRY )); then
    while read -r num; do
        [[ -n "$num" ]] || continue
        efibootmgr -b "$num" -B >/dev/null && ok "removed firmware entry Boot$num (systemd-boot)"
    done < <(efibootmgr -v | grep -i 'EFI\\systemd\\systemd-bootx64.efi' | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
else
    echo "   [dry-run] remove firmware entries pointing at \\EFI\\systemd\\systemd-bootx64.efi"
fi

# ── 5. pbt-grub-sync + apt hook ───────────────────────────────────────────────
echo; info "installing pbt-grub-sync and its apt hook"
SYNC=/usr/local/sbin/pbt-grub-sync
HOOK=/etc/apt/apt.conf.d/99-pbt-grub-sync
if (( DRY )); then
    echo "   [dry-run] write $SYNC, $HOOK; run pbt-grub-sync --force"
else
cat > "$SYNC" <<'SYNC'
#!/bin/bash
# pbt-grub-sync — keep GRUB on all Proxmox boot partitions (ESPs) current after GRUB
# package upgrades, and keep the firmware boot order sane. Installed by
# scripts/proxmox-grub-boot (homelab repo). Kernel updates are synced to the ESPs
# by Proxmox itself; GRUB *package* updates are not — this runs `proxmox-boot-tool
# reinit` for them. Called from /etc/apt/apt.conf.d/99-pbt-grub-sync after every dpkg
# run; does nothing unless the GRUB EFI package version changed since the last sync.
#
#   pbt-grub-sync          run if GRUB changed (what the apt hook does)
#   pbt-grub-sync --force  run regardless (e.g. after replacing a boot disk)
set -u
PKG=grub-efi-amd64-bin
STATE=/var/lib/pbt-grub-sync/version
LOG=/var/log/pbt-grub-sync.log
log() { echo "pbt-grub-sync: $*"; logger -t pbt-grub-sync "$*"; echo "$(date -Is) $*" >> "$LOG"; }

cur=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null) || exit 0
last=$(cat "$STATE" 2>/dev/null || true)
if [ "${1:-}" != --force ] && [ "$cur" = "$last" ]; then exit 0; fi
# only for GRUB-mode ESPs (never touch a systemd-boot setup); status prints to stderr
proxmox-boot-tool status 2>&1 | grep -q 'configured with: grub' || exit 0

log "GRUB ${last:-?} -> $cur: running proxmox-boot-tool reinit"
if ! proxmox-boot-tool reinit >> "$LOG" 2>&1; then
    log "ERROR: proxmox-boot-tool reinit failed — see $LOG; will retry after the next apt run"
    exit 1
fi

# firmware boot order: GRUB on each ESP (by device name: nvme0 before nvme1), then the
# firmware's own "UEFI OS" fallbacks for the same ESPs, then anything else
order=() fallbacks=()
devs=$(for uuid in $(cat /etc/kernel/proxmox-boot-uuids); do
           readlink -f "/dev/disk/by-uuid/$uuid" 2>/dev/null
       done | sort)
for dev in $devs; do
    [ -b "$dev" ] || continue
    partuuid=$(lsblk -no PARTUUID "$dev"); disk=/dev/$(lsblk -no PKNAME "$dev"); part=${dev##*[!0-9]}
    entry=$(efibootmgr | grep -i "$partuuid" | grep -i 'EFI\\proxmox\\shimx64.efi' | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
    if [ -z "$entry" ]; then
        efibootmgr --create --disk "$disk" --part "$part" --label "proxmox ($(basename "$disk"))" \
            --loader '\EFI\proxmox\shimx64.efi' >/dev/null
        entry=$(efibootmgr | grep -i "$partuuid" | grep -i 'EFI\\proxmox\\shimx64.efi' | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
        log "created firmware entry Boot$entry for $dev"
    fi
    [ -n "$entry" ] && order+=("$entry")
    fb=$(efibootmgr | grep -i "$partuuid" | grep -i 'EFI\\BOOT\\BOOTX64.EFI' | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
    [ -n "$fb" ] && fallbacks+=("$fb")
done
rest=$(efibootmgr | sed -nE 's/^BootOrder: //p' | tr ',' '\n')
new=$(printf '%s\n' "${order[@]}" "${fallbacks[@]}" $rest | awk 'NF && !seen[$0]++' | paste -sd, -)
[ -n "$new" ] && efibootmgr -o "$new" >/dev/null && log "boot order: $new"

mkdir -p "$(dirname "$STATE")" && echo "$cur" > "$STATE"
log "done — reboot once when convenient to use the new GRUB"
SYNC
chmod 755 "$SYNC"
cat > "$HOOK" <<'HOOK'
// installed by scripts/proxmox-grub-boot: after every dpkg run, re-sync GRUB onto the ESPs if a
// GRUB package changed (see /usr/local/sbin/pbt-grub-sync)
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/pbt-grub-sync ]; then /usr/local/sbin/pbt-grub-sync || true; fi"; };
HOOK
"$SYNC" --force
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
if (( DRY )); then
    info "dry run — nothing was changed"
else
    "$PBT" status 2>&1 | grep -E 'configured with' || true
    efibootmgr | grep -E '^Boot(Order|[0-9A-Fa-f]{4})' || true
    echo
    ok "done. Reboot, then check: cat /proc/cmdline  → must start with BOOT_IMAGE= (GRUB)"
    warn "from now on: never 'proxmox-boot-tool kernel pin --next-boot' or 'grub-reboot'"
fi
