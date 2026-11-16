#!/bin/bash
# Installs gpulimits (NVIDIA power limits and clock caps, applied at every boot).
#   install.sh               install or upgrade (keeps /etc/gpulimits.conf)
#   install.sh --uninstall   reset the cards to the driver's defaults and remove it
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/gpulimits/install.sh)
set -euo pipefail

REF="${GPULIMITS_REF:-main}"     # the repo branch gpulimits is downloaded from (main = passed CI)
SRC="https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/$REF/scripts/gpulimits/gpulimits"
BIN=/usr/local/sbin/gpulimits
UNIT=/etc/systemd/system/gpulimits.service

case "${1:-}" in
    -h|--help) echo "usage: install.sh | --uninstall   (then: gpulimits --help)"; exit 0 ;;
    ""|--uninstall) ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
esac
[[ $EUID -eq 0 ]] || { echo "run as root (sudo -i first)" >&2; exit 1; }

if [[ "${1:-}" == --uninstall ]]; then
    [[ -x $BIN ]] && command -v nvidia-smi >/dev/null && "$BIN" reset all || true
    systemctl disable --now gpulimits.service 2>/dev/null || true
    rm -f "$UNIT" "$BIN"; systemctl daemon-reload
    echo "gpulimits removed (cards back at the driver's defaults)"; exit 0
fi

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found: install the NVIDIA driver first" >&2; exit 1; }
here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
mkdir -p "$(dirname "$BIN")"
if [[ -f "$here/gpulimits" ]]; then install -m 755 "$here/gpulimits" "$BIN"; else curl -fsSL "$SRC" -o "$BIN.new" && install -m 755 "$BIN.new" "$BIN" && rm -f "$BIN.new"; fi

cat > "$UNIT" <<'EOF'
[Unit]
Description=NVIDIA power limits and clock caps (gpulimits)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gpulimits apply

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gpulimits.service >/dev/null 2>&1
echo "gpulimits installed: $BIN, applied at boot by gpulimits.service"
echo "next:  gpulimits status   then e.g.  sudo gpulimits set all --power 150"
