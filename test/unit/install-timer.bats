#!/usr/bin/env bats
# Unit tests of server/install-timer.sh rendering (installation itself needs
# root and systemd and is covered by test/migration/run.sh).

SCRIPT="$BATS_TEST_DIRNAME/../../server/install-timer.sh"
SERVER_DIR="$BATS_TEST_DIRNAME/../../server"

setup() {
  # shellcheck source=server/install-timer.sh
  source "$SCRIPT"
  set +u +o pipefail
}

@test "render_config quotes values so that the file sources back exactly" {
  file="$BATS_TEST_TMPDIR/matomo-update.env"
  render_config "$SERVER_DIR/matomo-update.env.example" "" "/opt/Matomo Stack & co" '/data/$x/backups' \
    'http://127.0.0.1:8000/matomo.php' 4000 >"$file"
  (
    source "$file"
    [ "$COMPOSE_DIR" = "/opt/Matomo Stack & co" ]
    [ "$BACKUP_DIR" = '/data/$x/backups' ]
    [ "$WAIT_TIMEOUT_SECONDS" = 4000 ]
    [ "$APP_SERVICE" = matomo ]
  )
  [ "$(configured_compose_dir "$file")" = "/opt/Matomo Stack & co" ]
}

@test "render_config keeps every key of the example" {
  file="$BATS_TEST_TMPDIR/matomo-update.env"
  render_config "$SERVER_DIR/matomo-update.env.example" "" /opt/m /b http://x/ 1 >"$file"
  [ "$(grep -cE '^[A-Z_]+=' "$file")" = "$(grep -cE '^[A-Z_]+=' "$SERVER_DIR/matomo-update.env.example")" ]
}

@test "render_config on an existing config replaces the given keys and keeps the others" {
  old="$BATS_TEST_TMPDIR/old.env"
  printf '%s\n' 'COMPOSE_DIR=/opt/m' 'WAIT_TIMEOUT_SECONDS=2400' 'BACKUP_RETENTION_DAYS=30' "HEALTH_URL='http://old/'" >"$old"
  file="$BATS_TEST_TMPDIR/new.env"
  render_config "$SERVER_DIR/matomo-update.env.example" "$old" /opt/m /b 'http://127.0.0.1:8000/matomo.php' 4000 >"$file"
  (
    source "$file"
    [ "$WAIT_TIMEOUT_SECONDS" = 4000 ]
    [ "$HEALTH_URL" = 'http://127.0.0.1:8000/matomo.php' ]
    [ "$BACKUP_RETENTION_DAYS" = 30 ]
    # keys missing in the old file come from the example
    [ "$APP_SERVICE" = matomo ]
  )
}

@test "the service unit gives a rollback time to finish after SIGTERM" {
  grep -qE '^TimeoutStopSec=[1-9]' "$SERVER_DIR/systemd/matomo-update.service"
}

@test "systemd_quote escapes quotes, backslashes and specifiers" {
  [ "$(systemd_quote '/opt/a b/x.sh')" = '"/opt/a b/x.sh"' ]
  [ "$(systemd_quote 'a"b\c%d')" = '"a\"b\\c%%d"' ]
}

@test "render_service fills ExecStart with quoted paths, & stays literal" {
  out=$(render_service "$SERVER_DIR/systemd/matomo-update.service" "/opt/m & m/matomo-update.sh" /etc/m/u.env)
  [[ "$out" == *'ExecStart="/opt/m & m/matomo-update.sh" "/etc/m/u.env"'* ]]
  [[ "$out" != *@UPDATE_* ]]
  [[ "$out" == *"UMask=0077"* ]]
}

@test "main rejects wrong arguments" {
  run main /opt/m /b http://x/
  [ "$status" -ne 0 ]
  run main /opt/m /b http://x/ soon
  [ "$status" -ne 0 ]
}
