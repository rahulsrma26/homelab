#!/usr/bin/env bash
# Validate Compose variants and real application config using disposable env values.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
docker build -q -t labber-unit -f "$repo/tests/labber/Dockerfile.unit" "$repo/tests/labber" >/dev/null
python3 "$repo/tests/services/validate.py" "$repo"
