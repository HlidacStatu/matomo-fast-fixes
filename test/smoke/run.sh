#!/usr/bin/env bash
# Smoke test of a candidate image: starts the stack, waits for health, checks
# s6 services (upstream services.sh), the HTTP endpoint and the Matomo version.
# Usage: test/smoke/run.sh IMAGE EXPECTED_MATOMO_VERSION TIMEOUT_SECONDS
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 IMAGE EXPECTED_MATOMO_VERSION TIMEOUT_SECONDS" >&2; exit 1; }
export MATOMO_IMAGE=$1
EXPECTED_VERSION=$2
TIMEOUT=$3

cd "$(dirname "${BASH_SOURCE[0]}")"

cleanup() {
  docker compose logs --no-color >compose.log 2>&1 || true
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose up -d --wait --wait-timeout "$TIMEOUT"

echo "--- s6 services"
docker compose exec -T matomo sh -s <services.sh
docker compose exec -T cron sh -s <services.sh

echo "--- HTTP"
curl -fsS -o /dev/null -w '%{http_code}\n' --retry 10 --retry-all-errors --retry-delay 2 http://127.0.0.1:8000/

echo "--- Matomo version"
# shellcheck disable=SC2016
actual=$(docker compose exec -T matomo php -r 'require "/var/www/matomo/core/Version.php"; echo \Piwik\Version::VERSION;')
echo "$actual"
[[ $actual == "$EXPECTED_VERSION" ]] || { echo "expected Matomo $EXPECTED_VERSION, got $actual" >&2; exit 1; }

echo "smoke test passed"
