#!/usr/bin/env bash
# Runs compose_up_wait (server/lib/host.sh) with the Docker Compose of
# CLI_IMAGE against the host's Docker daemon. Docker Compose before v5.0.2
# fails `up --wait` on a service with `healthcheck: disable: true`
# (docker/compose#13522), which broke the cron sidecar start on servers.
# Usage: test/compose-compat/run.sh CLI_IMAGE SERVICE_IMAGE TIMEOUT_SECONDS
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 CLI_IMAGE SERVICE_IMAGE TIMEOUT_SECONDS" >&2; exit 1; }
CLI_IMAGE=$1
SERVICE_IMAGE=$2
TIMEOUT=$3
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

docker pull -q "$SERVICE_IMAGE" >/dev/null
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT:/src:ro" \
  -e COMPAT_IMAGE="$SERVICE_IMAGE" -e TIMEOUT="$TIMEOUT" \
  "$CLI_IMAGE" sh -c 'apk add -q --no-progress bash jq >/dev/null && exec bash /src/test/compose-compat/inner.sh'
