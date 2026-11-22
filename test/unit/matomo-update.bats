#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Unit tests of server/matomo-update.sh helpers. The full update/rollback flow
# against real containers is covered by test/integration/run.sh.

SCRIPT="$BATS_TEST_DIRNAME/../../server/matomo-update.sh"
EXAMPLE="$BATS_TEST_DIRNAME/../../server/matomo-update.env.example"

setup() {
  # shellcheck source=server/matomo-update.sh
  source "$SCRIPT"
  # The script enables strict mode; bats manages errexit itself.
  set +u +o pipefail
  CONFIG="$BATS_TEST_TMPDIR/matomo-update.env"
  cp "$EXAMPLE" "$CONFIG"
}

@test "the example config contains every required key" {
  run load_server_config "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "a missing config file is a configuration error (exit 2)" {
  run load_server_config "$BATS_TEST_TMPDIR/nope.env"
  [ "$status" -eq 2 ]
  [ "$(jq -r .event <<<"$output")" = "config_invalid" ]
}

@test "missing keys are reported together (exit 2)" {
  sed -i.bak -e '/^HEALTH_URL=/d' -e '/^STATE_DIR=/d' "$CONFIG"
  run load_server_config "$CONFIG"
  [ "$status" -eq 2 ]
  [[ "$(jq -r .missing <<<"$output")" == *HEALTH_URL* ]]
  [[ "$(jq -r .missing <<<"$output")" == *STATE_DIR* ]]
}

@test "non-numeric timeouts are rejected (exit 2)" {
  sed -i.bak -e 's/^WAIT_TIMEOUT_SECONDS=.*/WAIT_TIMEOUT_SECONDS=10m/' "$CONFIG"
  run load_server_config "$CONFIG"
  [ "$status" -eq 2 ]
  [ "$(jq -r .key <<<"$output")" = "WAIT_TIMEOUT_SECONDS" ]
}

@test "the script without arguments exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [ "$(jq -r .event <<<"$output")" = "usage" ]
}

@test "log writes one valid JSON line to stdout and LOG_FILE" {
  LOG_FILE="$BATS_TEST_TMPDIR/update.log"
  run log info image_changed 'quote " and \ backslash' service matomo new_id sha256:abc
  [ "$status" -eq 0 ]
  [ "$(jq -r .level <<<"$output")" = "info" ]
  [ "$(jq -r .event <<<"$output")" = "image_changed" ]
  [ "$(jq -r .message <<<"$output")" = 'quote " and \ backslash' ]
  [ "$(jq -r .service <<<"$output")" = "matomo" ]
  [ "$(jq -r .new_id <<<"$output")" = "sha256:abc" ]
  [ "$(jq -r .run_id <<<"$output")" = "$RUN_ID" ]
  [[ "$(jq -r .ts <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [ "$(wc -l <"$LOG_FILE" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$LOG_FILE")" = "$output" ]
}

@test "blocked images are recorded once and matched exactly" {
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  run ! is_blocked ghcr.io/x/matomo:5 sha256:bad
  block_image ghcr.io/x/matomo:5 sha256:bad
  block_image ghcr.io/x/matomo:5 sha256:bad
  is_blocked ghcr.io/x/matomo:5 sha256:bad
  run ! is_blocked ghcr.io/x/matomo:5 sha256:good
  run ! is_blocked ghcr.io/x/matomo:6 sha256:bad
  [ "$(wc -l <"$STATE_DIR/blocked-images" | tr -d ' ')" -eq 1 ]
}

@test "service helpers classify changed services" {
  APP_SERVICE=matomo CRON_SERVICE=cron DB_SERVICE=db
  SERVICES=(db redis matomo cron)
  [ "$(service_index matomo)" = "2" ]
  run ! service_index nope
  [ "$(services_without_cron | tr '\n' ' ')" = "db redis matomo " ]

  CHANGED=(redis)
  run ! app_changed
  run ! app_or_db_changed

  CHANGED=(db)
  run ! app_changed
  app_or_db_changed

  CHANGED=(redis cron)
  app_changed
  app_or_db_changed
}

@test "clean_compose_environment keeps the script's own configuration" {
  cd "$BATS_TEST_TMPDIR"
  printf "MATOMO_IMAGE='x'\n" >.env
  export COMPOSE_DIR=/opt/m COMPOSE_FILE=/bogus.yml MATOMO_IMAGE=bogus
  clean_compose_environment
  [ "$COMPOSE_DIR" = /opt/m ]
  [ -z "${COMPOSE_FILE:-}" ]
  [ -z "${MATOMO_IMAGE:-}" ]
}

@test "clean_compose_environment also unsets keys written as 'KEY = value' or 'export KEY='" {
  cd "$BATS_TEST_TMPDIR"
  printf '%s\n' 'MYSQL_PASSWORD = file-value' 'export MATOMO_IMAGE=x' '  TZ=UTC' '# COMMENTED=1' >.env
  export MYSQL_PASSWORD=shell MATOMO_IMAGE=shell TZ=shell COMMENTED=keep
  clean_compose_environment
  [ -z "${MYSQL_PASSWORD:-}" ]
  [ -z "${MATOMO_IMAGE:-}" ]
  [ -z "${TZ:-}" ]
  [ "$COMMENTED" = keep ]
}

@test "the database dump falls back to mysqldump for old MariaDB images" {
  [[ "$DB_DUMP_SNIPPET" == *"command -v mariadb-dump"*"dump=mysqldump"* ]]
  ! grep -q 'exec mariadb-dump' "$SCRIPT"
}
