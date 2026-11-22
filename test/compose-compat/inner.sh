#!/usr/bin/env bash
# Inside the CLI container of test/compose-compat/run.sh.
set -euo pipefail
# shellcheck source=server/lib/host.sh
source /src/server/lib/host.sh
: "${TIMEOUT:?}" "${COMPAT_IMAGE:?}"

cd /src/test/compose-compat
compat() { docker compose "$@"; }
cleanup() { compat down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

docker compose version

echo "--- disabled healthchecks are detected"
[[ $(compat config --format json | healthcheck_disabled_services | sort | tr '\n' ' ') == "crashing sidecar " ]] ||
  fail "healthcheck_disabled_services"

echo "--- compose_up_wait starts the app and the sidecar"
compose_up_wait compat "$TIMEOUT" app sidecar || fail "compose_up_wait app sidecar"
[[ $(docker inspect --format '{{.State.Health.Status}}' "$(compat ps -q app)") == healthy ]] || fail "app is not healthy"
containers_running "$(compat ps -q sidecar)" || fail "sidecar is not running"

echo "--- compose_up_wait fails for an exited sidecar"
if compose_up_wait compat "$TIMEOUT" crashing; then
  fail "compose_up_wait accepted an exited container"
fi
cleanup

echo "--- plain up --wait on this Compose version"
if compat up -d --wait --wait-timeout "$TIMEOUT" app sidecar >/dev/null 2>&1; then
  echo "this Compose version accepts --wait on a disabled healthcheck"
else
  echo "this Compose version rejects --wait on a disabled healthcheck (docker/compose#13522)"
fi

echo "compose compatibility test passed"
