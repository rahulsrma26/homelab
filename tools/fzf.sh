#!/usr/bin/env bash
set -euo pipefail

if command -v fzf &>/dev/null; then
    echo "fzf $(fzf --version) already installed — updating..."
    [[ -d ~/.fzf ]] && git -C ~/.fzf pull
else
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
fi

~/.fzf/install --all
