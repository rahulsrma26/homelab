#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/rahulsrma26/homelab.git"
DEPLOY_BASE="/opt/homelab/services"
TMPDIR="/tmp/homelab-deploy-$$"

# Cleanup on exit
trap 'rm -rf "$TMPDIR"' EXIT

# Check dependencies
for cmd in git docker curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

echo "Cloning repository (sparse)..."
git clone --depth=1 --sparse --filter=blob:none "$REPO" "$TMPDIR" -q
git -C "$TMPDIR" sparse-checkout set services/

# Discover services
SERVICES=()
while IFS= read -r line; do
  SERVICES+=("$line")
done < <(
  find "$TMPDIR/services" -name "docker-compose.yml" \
    | sed "s|$TMPDIR/services/||" \
    | sed 's|/docker-compose.yml||' \
    | sort
)

if [ ${#SERVICES[@]} -eq 0 ]; then
  echo "No services found in repository."
  exit 1
fi

# Show menu
echo ""
echo "Available services:"
for i in "${!SERVICES[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${SERVICES[$i]}"
done
echo ""

read -rp "Select service [1-${#SERVICES[@]}]: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#SERVICES[@]}" ]; then
  echo "Invalid selection."
  exit 1
fi

SERVICE="${SERVICES[$((SELECTION-1))]}"
SRC="$TMPDIR/services/$SERVICE"
DEST="$DEPLOY_BASE/$SERVICE"

echo ""
echo "Service: $SERVICE"
echo "Target:  $DEST"

# Existing deployment
if [ -d "$DEST" ]; then
  echo ""
  read -rp "Service already deployed. Update? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  echo ""
  echo "Stopping service..."
  docker compose -f "$DEST/docker-compose.yml" down

  echo "Removing old images..."
  OLD_IMAGES=$(docker compose -f "$DEST/docker-compose.yml" images -q 2>/dev/null || true)
  if [ -n "$OLD_IMAGES" ]; then
    docker rmi $OLD_IMAGES 2>/dev/null || true
  fi

  echo "Updating files (preserving .env)..."
  # Copy all files except .env
  find "$SRC" -type f | while read -r file; do
    relative="${file#$SRC/}"
    if [ "$relative" = ".env" ]; then
      continue
    fi
    mkdir -p "$DEST/$(dirname "$relative")"
    cp "$file" "$DEST/$relative"
  done

else
  # Fresh install
  mkdir -p "$DEST"
  cp -r "$SRC/." "$DEST/"

  # Create .env from example if needed
  if [ -f "$DEST/.env.example" ] && [ ! -f "$DEST/.env" ]; then
    cp "$DEST/.env.example" "$DEST/.env"
    echo ""
    echo ".env created from .env.example at $DEST/.env"
    echo "Edit it now, then press Enter to continue (or Ctrl+C to abort)."
    read -rp "Press Enter when ready: "
  fi
fi

echo ""
echo "Pulling latest images..."
docker compose -f "$DEST/docker-compose.yml" pull

echo "Starting service..."
docker compose -f "$DEST/docker-compose.yml" up -d

echo ""
echo "Done. $SERVICE is running."
docker compose -f "$DEST/docker-compose.yml" ps
