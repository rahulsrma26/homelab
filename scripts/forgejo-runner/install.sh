#!/usr/bin/env bash
# scripts/forgejo-runner — install, register and update a native Forgejo Actions runner on a
# Debian machine with Docker (e.g. a CI VM).
#
# Native, not in a container: jobs with the "host" label run directly on this machine, so
# checkout paths exist on the Docker host (bind mounts in tests work) and the machine's own
# tools (make, python3, git, Docker) are used. The runner runs as its own user
# "forgejo-runner" (in the docker group: root-equivalent on this machine, not a sandbox),
# from a systemd unit. Only for trusted repositories.
#
# What it does:
#   - installs git and nodejs (JavaScript actions like actions/checkout run on the host)
#   - downloads the runner binary from code.forgejo.org and checks its SHA-256
#   - creates the user, /etc/forgejo-runner (config, mode 600) and /var/lib/forgejo-runner
#   - writes the systemd unit (forgejo-runner.service)
#   - registers: asks for the Forgejo URL and the runner's UUID + token (the runner and its
#     name are created in Forgejo first); the token is read hidden
#   - starts the runner once it is registered
#
# Usage (as root; on a sudo machine: sudo -i first):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/forgejo-runner/install.sh)
#   flags: --version X.Y.Z (default: the latest release)  --register  --url URL  --uuid UUID
#          --labels "a:host,b:host"  --capacity N  --status  --dry-run  --yes
#   --uninstall: removes the runner, its user, config (the registration) and work folder
#   the token: asked hidden, or FORGEJO_RUNNER_TOKEN in the environment (never a flag)
#
# Re-running is safe: it updates the binary (to --version, else the latest) and the unit,
# restarts a running runner, and keeps the config and its registration. --register
# replaces the registration (and the labels/capacity).
set -euo pipefail

VERSION="" REGISTER=0 URL="" UUID="" LABELS="" CAPACITY="" STATUS=0 DRY=0 YES=0 UNINSTALL=0
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed '$d; s/^# \{0,1\}//' || true; }
while (( $# )); do
    case "$1" in
        --version) VERSION="${2:-}"; shift ;;
        --register) REGISTER=1 ;;
        --url) URL="${2:-}"; shift ;;
        --uuid) UUID="${2:-}"; shift ;;
        --labels) LABELS="${2:-}"; shift ;;
        --capacity) CAPACITY="${2:-}"; shift ;;
        --status) STATUS=1 ;;
        --dry-run|-n) DRY=1 ;;
        --yes|-y) YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ -t 1 ]]; then R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' C=$'\033[0;36m' N=$'\033[0m'; else R='' G='' Y='' C='' N=''; fi
info() { echo -e "${C}:: $*${N}"; }
ok()   { echo -e "${G}✓ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
die()  { echo -e "${R}error: $*${N}" >&2; exit 1; }
interactive() { (( ! YES )) && [[ -t 0 ]]; }

RELEASES="${FORGEJO_RUNNER_RELEASES:-https://code.forgejo.org/forgejo/runner/releases}"
API="${FORGEJO_RUNNER_API:-https://code.forgejo.org/api/v1/repos/forgejo/runner/releases/latest}"
BIN=/usr/local/bin/forgejo-runner
ETC=/etc/forgejo-runner CONF=/etc/forgejo-runner/config.yml
HOME_DIR=/var/lib/forgejo-runner WORK=/var/lib/forgejo-runner/work
UNIT=/etc/systemd/system/forgejo-runner.service
RUSER=forgejo-runner

installed_version() { [[ -x "$BIN" ]] && "$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
registered() { [[ -f "$CONF" ]] && grep -qE '^\s+uuid: "[0-9a-fA-F-]{36}"' "$CONF"; }

status() {
    local v; v=$(installed_version)
    echo "binary      ${v:-not installed} ($BIN)"
    echo "service     $(systemctl is-active forgejo-runner.service 2>/dev/null || true), $(systemctl is-enabled forgejo-runner.service 2>/dev/null || echo not installed)"
    if registered; then
        echo "registered  yes: $(sed -n 's/^ *url: "\(.*\)"/\1/p' "$CONF" | head -1)"
        echo "labels      $(sed -n '/^  labels:/,/^[a-z]/s/^ *- "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONF" | paste -sd' ' -)"
    else
        echo "registered  no (run with --register)"
    fi
    echo "docker      $(sudo -u "$RUSER" docker info --format '{{.ServerVersion}}' 2>/dev/null || echo "not reachable by $RUSER")"
    if systemctl cat forgejo-runner.service >/dev/null 2>&1; then
        echo "last log:"; journalctl -u forgejo-runner.service -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
    fi
}

(( EUID == 0 )) || die "run as root (on a sudo machine: sudo -i first)"
if (( STATUS )); then status; exit 0; fi
command -v apt-get >/dev/null || die "needs a Debian-based system (apt)"
command -v systemctl >/dev/null || die "needs systemd"

if (( UNINSTALL )); then
    if (( ! YES )); then
        [[ -t 0 ]] || die "--uninstall without a terminal needs --yes"
        read -rp "Remove the runner, its user, config (the registration) and work folder? [y/N] " a
        [[ "$a" == [yY]* ]] || die "cancelled — nothing changed"
    fi
    systemctl disable --now forgejo-runner.service >/dev/null 2>&1 || true
    rm -f "$UNIT" "$BIN"; systemctl daemon-reload
    if id "$RUSER" >/dev/null 2>&1; then userdel "$RUSER" 2>/dev/null || true; fi
    rm -rf "$ETC" "$HOME_DIR"
    ok "runner removed (also remove it in Forgejo: Settings → Actions → Runners)"
    exit 0
fi

command -v docker >/dev/null || die "needs Docker (e.g. labber setup with Docker): the jobs run containers"
docker info >/dev/null 2>&1 || die "Docker isn't running (systemctl status docker)"
case "$(dpkg --print-architecture)" in
    amd64) ARCH=amd64 ;; arm64) ARCH=arm64 ;;
    *) die "no Forgejo runner build for $(dpkg --print-architecture)" ;;
esac
[[ -z "$CAPACITY" || "$CAPACITY" =~ ^[1-9][0-9]?$ ]] || die "--capacity: a number from 1 to 99"
[[ -z "$UUID" || "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "--uuid: the 36-character UUID Forgejo shows"
[[ -z "$URL" || "$URL" =~ ^https?://[^[:space:]\"]+$ ]] || die "--url: http(s)://… (Forgejo's address)"
[[ "$LABELS" != *'"'* ]] || die "--labels: no quotes"

# the version: given, else the latest release
if [[ -z "$VERSION" ]]; then
    VERSION=$(curl -fsSL "$API" 2>/dev/null | grep -oE '"tag_name": *"v[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [[ -n "$VERSION" ]] || die "couldn't look up the latest release ($API): give --version X.Y.Z"
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version: X.Y.Z"
OLD=$(installed_version)
UPDATE_BIN=1; [[ "$OLD" == "$VERSION" ]] && UPDATE_BIN=0

# registration: asked on the first install (in a terminal) or with --register
DO_REG=0
if (( REGISTER )) || [[ -n "$UUID" ]]; then DO_REG=1
elif ! registered && interactive && (( ! DRY )); then
    read -rp "Register this runner now? You need Forgejo's runner UUID and token. [Y/n] " a || true
    [[ "$a" == [nN]* ]] || DO_REG=1
fi

# the registration answers, asked and checked before anything changes
if (( DO_REG )) && (( ! DRY )); then
    if [[ -z "$URL" ]]; then
        interactive || die "--register without a terminal needs --url"
        read -rp "Forgejo URL (e.g. https://git.example.com): " URL || true
        [[ "$URL" =~ ^https?://[^[:space:]\"]+$ ]] || die "not a URL: $URL"
    fi
    if [[ -z "$UUID" ]]; then
        interactive || die "--register without a terminal needs --uuid"
        read -rp "Runner UUID (from Forgejo's Create new runner): " UUID || true
        [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "not a UUID: $UUID"
    fi
    TOKEN="${FORGEJO_RUNNER_TOKEN:-}"
    if [[ -z "$TOKEN" ]]; then
        interactive || die "--register without a terminal needs FORGEJO_RUNNER_TOKEN in the environment"
        read -rsp "Runner token (hidden): " TOKEN || true; echo
    fi
    [[ "$TOKEN" =~ ^[A-Za-z0-9_-]{16,}$ ]] || die "the token looks wrong (letters/digits, at least 16)"
fi

if (( DRY )); then
    echo "--dry-run: nothing was changed. A run would:"
    if (( UPDATE_BIN )); then echo "  install forgejo-runner $VERSION ($ARCH)${OLD:+, replacing $OLD} → $BIN"
    else echo "  keep forgejo-runner $VERSION"; fi
    id "$RUSER" >/dev/null 2>&1 || echo "  create the user $RUSER (docker group), $ETC, $WORK"
    echo "  apt install git nodejs (if missing), write $UNIT"
    if (( DO_REG )); then echo "  register with ${URL:-<asked>}, labels ${LABELS:-labber-ci:host}, capacity ${CAPACITY:-1}"
    elif registered; then echo "  keep the registration in $CONF"
    else echo "  leave it unregistered (run again with --register)"; fi
    exit 0
fi

# 0. what host jobs need beyond the runner: git, and node for JavaScript actions
missing=()
for p in git nodejs ca-certificates curl; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then
    info "installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" >/dev/null || die "apt-get install ${missing[*]} failed (apt-get update first?)"
fi

# 1. the binary, checked against the release's SHA-256
if (( UPDATE_BIN )); then
    info "downloading forgejo-runner $VERSION ($ARCH)"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    file="forgejo-runner-$VERSION-linux-$ARCH"
    curl -fsSL -o "$tmp/$file" "$RELEASES/download/v$VERSION/$file" || die "download failed: $RELEASES/download/v$VERSION/$file"
    curl -fsSL -o "$tmp/$file.sha256" "$RELEASES/download/v$VERSION/$file.sha256" || die "no checksum for $file"
    (cd "$tmp" && sha256sum -c --quiet "$file.sha256") || die "checksum mismatch for $file: not installed"
    chmod 755 "$tmp/$file"
    "$tmp/$file" --version >/dev/null 2>&1 || die "the downloaded binary doesn't run here"
    install -m 755 "$tmp/$file" "$BIN"
    if [[ -n "$OLD" ]]; then ok "forgejo-runner $OLD → $VERSION"; else ok "forgejo-runner $VERSION installed ($BIN)"; fi
else
    ok "forgejo-runner $VERSION already installed"
fi

# 2. the user and folders
if ! id "$RUSER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HOME_DIR" --shell /bin/bash "$RUSER"
    ok "user $RUSER created"
fi
usermod -aG docker "$RUSER"
install -d -m 700 -o "$RUSER" -g "$RUSER" "$ETC" "$WORK"

# 3. the unit (always rewritten: it belongs to this script)
cat > "$UNIT" <<'EOF'
# installed by scripts/forgejo-runner/install.sh — re-running it rewrites this file
[Unit]
Description=Forgejo Actions runner (trusted repositories)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
User=forgejo-runner
Group=forgejo-runner
SupplementaryGroups=docker
WorkingDirectory=/var/lib/forgejo-runner
Environment=HOME=/var/lib/forgejo-runner
ExecStart=/usr/local/bin/forgejo-runner daemon --config /etc/forgejo-runner/config.yml
Restart=on-failure
RestartSec=5
# test containers running as non-root must be able to read bind-mounted checkout files;
# the registration stays in the mode-600 config
UMask=0022

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable forgejo-runner.service >/dev/null 2>&1

# 4. the registration: the whole config is written from the answers
if (( DO_REG )); then
    LABELS="${LABELS:-labber-ci:host}" CAPACITY="${CAPACITY:-1}"
    new=$(mktemp "$ETC/.config.XXXXXX")
    {
        echo "# written by scripts/forgejo-runner/install.sh --register; re-registering rewrites it"
        echo "log:"
        echo "  level: info"
        echo "runner:"
        echo "  file: $HOME_DIR/.runner"
        echo "  capacity: $CAPACITY"
        echo "  timeout: 2h"
        echo "  labels:"
        for l in ${LABELS//,/ }; do echo "    - \"$l\""; done
        echo "cache:"
        echo "  enabled: false"
        echo "host:"
        echo "  workdir_parent: $WORK"
        echo "server:"
        echo "  connections:"
        echo "    forgejo:"
        echo "      url: \"${URL%/}\""
        echo "      uuid: \"$UUID\""
        echo "      token: \"$TOKEN\""
    } > "$new"
    unset TOKEN
    chown "$RUSER:$RUSER" "$new"; chmod 600 "$new"; mv -f "$new" "$CONF"
    ok "registered with ${URL%/} (labels: $LABELS)"
fi

# 5. run it once registered
if registered; then
    systemctl restart forgejo-runner.service
    sleep 3
    systemctl is-active --quiet forgejo-runner.service || { journalctl -u forgejo-runner.service -n 20 --no-pager -o cat; die "the runner didn't stay up (log above)"; }
    ok "runner running"
else
    systemctl stop forgejo-runner.service >/dev/null 2>&1 || true
    warn "not registered yet: in Forgejo, Settings → Actions → Runners → Create new runner, then run this again with --register"
fi
echo
status
