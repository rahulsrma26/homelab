#!/usr/bin/env bash
# The weekly Renovate run (renovate.timer): a fresh shallow copy of homelab's default branch, only
# to list its services/ (nothing from it is run), then the installed run.sh. Settings in
# /etc/renovate/renovate.conf (forgejo=, owner=, git_author=); tokens in /etc/renovate/token and (optional) github-token, root only.
set -euo pipefail
conf=/etc/renovate/renovate.conf
url=$(sed -n 's/^forgejo=//p' "$conf"); owner=$(sed -n 's/^owner=//p' "$conf")
[[ -n "$url" && -n "$owner" ]] || { echo "error: forgejo= and owner= in $conf" >&2; exit 1; }
RENOVATE_TOKEN=$(< /etc/renovate/token); export RENOVATE_TOKEN
if [[ -s /etc/renovate/github-token ]]; then RENOVATE_GITHUB_COM_TOKEN=$(< /etc/renovate/github-token); export RENOVATE_GITHUB_COM_TOKEN; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 "$url/$owner/homelab.git" "$work/homelab"
cd "$work/homelab"
# the commits' author: Forgejo may not show Renovate its own email (then Renovate refuses to start)
author=$(sed -n 's/^git_author=//p' "$conf"); author=${author:-Renovate <renovate@localhost>}
bash /opt/renovate/run.sh "$url" "$owner" --git-author="$author" "$@"
