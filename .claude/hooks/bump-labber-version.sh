#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

# Extract file_path from tool input JSON
if command -v jq &>/dev/null; then
    file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
else
    file_path=$(echo "$input" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

[[ "$file_path" == */services/labber ]] || exit 0

repo_root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel) || exit 0

# Read version from last commit
head_version=$(git -C "$repo_root" show HEAD:services/labber 2>/dev/null \
    | grep '^VERSION=' | cut -d'"' -f2) || exit 0
[[ -n "$head_version" ]] || exit 0

# Read version in working file
current_version=$(grep '^VERSION=' "$file_path" | cut -d'"' -f2)

# Skip if already bumped beyond HEAD
[[ "$current_version" == "$head_version" ]] || exit 0

IFS='.' read -r major minor patch <<< "$head_version"
new_version="$major.$minor.$((patch + 1))"

if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s/^VERSION=\"[^\"]*\"/VERSION=\"$new_version\"/" "$file_path"
else
    sed -i '' "s/^VERSION=\"[^\"]*\"/VERSION=\"$new_version\"/" "$file_path"
fi

echo "labber: bumped $head_version → $new_version"
