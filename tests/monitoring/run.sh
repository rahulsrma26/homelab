#!/usr/bin/env bash
# Validate and unit-test the Prometheus alert rules with promtool (needs only Docker).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rules="$(cd "$here/../../services/monitoring/config/prometheus" && pwd)"
image=prom/prometheus:v3.1.0    # keep in step with services/monitoring/docker-compose.yml
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" check rules /rules/alert.rules.yml
docker run --rm -v "$rules:/rules:ro" -v "$here:/tests:ro" --entrypoint promtool "$image" test rules /tests/alert-rules.test.yml
