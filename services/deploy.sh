#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.1"
REPO="https://github.com/rahulsrma26/homelab.git"
DEPLOY_BASE="/opt/homelab/services"
TMPDIR="/tmp/homelab-deploy-$$"

# Parse arguments
AUTO_YES=0
SERVICE_ARG=""

for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
    -h|--help)
      echo "deploy.sh v$VERSION"
      echo ""
      echo "Usage: deploy.sh [service] [-y] [-h]"
      echo ""
      echo "  service    Name of the service to deploy (e.g. monitoring, termix)"
      echo "  -y|--yes   Auto-yes to all prompts"
      echo "  -h|--help  Show this help"
      echo ""
      echo "Examples:"
      echo "  deploy.sh                  # interactive menu"
      echo "  deploy.sh monitoring       # select service, ask questions"
      echo "  deploy.sh monitoring --yes # fully non-interactive"
      exit 0 ;;
    -*) echo "Unknown flag: $arg. Use -h for help."; exit 1 ;;
    *)  SERVICE_ARG="$arg" ;;
  esac
done

# Helper: prompt or auto-yes
confirm() {
  local prompt="$1"
  if [ "$AUTO_YES" = "1" ]; then
    echo "$prompt [auto: y]"
    return 0
  fi
  read -rp "$prompt [y/N]: " REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]]
}

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

# Resolve service from argument or menu
if [ -n "$SERVICE_ARG" ]; then
  SERVICE=""
  for s in "${SERVICES[@]}"; do
    if [ "$s" = "$SERVICE_ARG" ]; then
      SERVICE="$s"
      break
    fi
  done
  if [ -z "$SERVICE" ]; then
    echo "Service '$SERVICE_ARG' not found. Available services:"
    for s in "${SERVICES[@]}"; do echo "  $s"; done
    exit 1
  fi
else
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
fi

SRC="$TMPDIR/services/$SERVICE"
DEST="$DEPLOY_BASE/$SERVICE"

echo ""
echo "Service: $SERVICE"
echo "Target:  $DEST"

# Show README if available
if [ -f "$SRC/README.txt" ]; then
  echo ""
  echo "----------------------------------------"
  cat "$SRC/README.txt"
  echo "----------------------------------------"
  echo ""
  if ! confirm "Continue with deployment?"; then
    echo "Aborted."
    exit 0
  fi
fi

# Existing deployment
if [ -d "$DEST" ]; then
  echo ""
  if ! confirm "Service already deployed. Update?"; then
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
  fi
fi

# Start options
echo ""
if [ "$AUTO_YES" = "1" ]; then
  ACTION="2"
else
  read -rp "Start the stack now? [Y/n]: " ACTION
fi

if [[ "$ACTION" =~ ^[Nn]$ ]]; then
  echo ""
  echo "Edit your .env at $DEST/.env then run:"
  echo "  cd $DEST && docker compose up -d"
  exit 0
fi

cd "$DEST"

echo ""
echo "Pulling latest images..."
docker compose pull

echo "Starting service..."
docker compose up -d

echo ""
echo "Done. $SERVICE is running."
docker compose ps
