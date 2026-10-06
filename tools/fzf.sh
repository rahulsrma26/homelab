#!/usr/bin/env bash
set -euo pipefail

# Check for ~/.fzf itself, not `command -v fzf`: ~/.fzf/bin is only on PATH once
# ~/.bashrc has been loaded, so scripts and `labber tool fzf` wouldn't find it.
if [[ -d ~/.fzf/.git ]]; then
    echo "fzf already in ~/.fzf — updating..."
    git -C ~/.fzf pull --ff-only
elif command -v fzf &>/dev/null; then
    echo "fzf $(fzf --version) is already installed from elsewhere (e.g. apt) — leaving it alone"
    exit 0
else
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
fi

~/.fzf/install --all
