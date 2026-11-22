#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Unit tests of server/migrate-from-crazymax.sh helpers. The full migration
# and rollback against real containers is covered by test/migration/run.sh.

SCRIPT="$BATS_TEST_DIRNAME/../../server/migrate-from-crazymax.sh"
ENV_EXAMPLE="$BATS_TEST_DIRNAME/../../server/.env.example"

setup() {
  # shellcheck source=server/migrate-from-crazymax.sh
  source "$SCRIPT"
  # The script enables strict mode; bats manages errexit itself.
  set +u +o pipefail
}

@test "ini_value reads quoted and unquoted values from the right section" {
  ini="$BATS_TEST_TMPDIR/config.ini.php"
  printf '%s\r\n' '; <?php exit; ?> DO NOT REMOVE THIS LINE' '[General]' 'host = "wrong"' \
    '[database] ' 'host = "db"' 'username = matomo' '  dbname   =   "matomo_prod"  ' \
    'password = "p=ss"' '[RedisCache]' 'host = "redis"' >"$ini"
  [ "$(ini_value "$ini" database host)" = "db" ]
  [ "$(ini_value "$ini" database username)" = "matomo" ]
  [ "$(ini_value "$ini" database dbname)" = "matomo_prod" ]
  [ "$(ini_value "$ini" database password)" = "p=ss" ]
  [ "$(ini_value "$ini" RedisCache host)" = "redis" ]
  [ "$(ini_value "$ini" database missing)" = "" ]
}

@test "env_file_value does not shell-parse values" {
  [ "$(env_file_value "$ENV_EXAMPLE" CRON_ARCHIVE)" = "0 * * * *" ]
  [ "$(env_file_value "$ENV_EXAMPLE" MATOMO_IMAGE)" = "ghcr.io/hlidacstatu/matomo:5" ]
  run env_file_value "$ENV_EXAMPLE" NOT_THERE
  [ "$status" -ne 0 ]
}

@test "write_env_file quotes values literally, sorts keys and drops excluded ones" {
  file="$BATS_TEST_TMPDIR/matomo.env"
  write_env_file "$file" '{"B":"x y # z","A":"a$b","TZ":"UTC","SIDECAR_CRON":"1"}' TZ SIDECAR_CRON
  [ "$(cat "$file")" = "$(printf "%s\n%s" "A='a\$b'" "B='x y # z'")" ]
  [ "$(stat -c %a "$file")" = "600" ]
}

@test "write_env_file refuses values it cannot quote safely" {
  run write_env_file "$BATS_TEST_TMPDIR/x.env" '{"P":"it'"'"'s"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *unsupported_value* ]]
  run write_env_file "$BATS_TEST_TMPDIR/x.env" '{"P":"a\nb"}'
  [ "$status" -eq 1 ]
}

@test "generate_config writes every .env.example key, single-quoted, mode 600" {
  # The only external call is the final `docker compose config` validation.
  docker() { return 0; }
  while IFS= read -r key; do ENV_VALUES[$key]="value of $key"; done < <(env_file_keys "$ENV_EXAMPLE")
  MATOMO_ENV_JSON='{"MEMORY_LIMIT":"512M","TZ":"UTC","CRON_ARCHIVE":"x"}'
  MSMTPD_ENV_JSON='{"SMTP_HOST":"smtp.example.org"}'
  GEOIP_ENV_JSON='{"LICENSE_KEY":"k"}'
  dir="$BATS_TEST_TMPDIR/new"
  generate_config "$dir"
  [ "$(env_file_keys "$dir/.env")" = "$(env_file_keys "$ENV_EXAMPLE")" ]
  grep -qx "TZ='value of TZ'" "$dir/.env"
  [ "$(stat -c %a "$dir/.env")" = "600" ]
  [ "$(cat "$dir/matomo.env")" = "MEMORY_LIMIT='512M'" ]
  [ -f "$dir/compose.yml" ]
}

@test "generate_config fails when a .env key has no value" {
  docker() { return 0; }
  ENV_VALUES=([TZ]=UTC)
  run generate_config "$BATS_TEST_TMPDIR/new"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no value for .env key"* ]]
}

@test "movable_entries keeps data directories, their parents, backups and NEW_DIR" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  mkdir -p "$OLD_DIR/data/db" "$OLD_DIR/data/web" "$OLD_DIR/geoip" "$OLD_DIR/backups" "$OLD_DIR/new" "$OLD_DIR/scripts"
  touch "$OLD_DIR/docker-compose.yml" "$OLD_DIR/matomo.env" "$OLD_DIR/.env" "$OLD_DIR/notes.txt"
  ENV_VALUES[MATOMO_DB_DIR]="$OLD_DIR/data/db"
  ENV_VALUES[MATOMO_WEB_DIR]="$OLD_DIR/data/web"
  ENV_VALUES[MATOMO_GEOIP_DIR]="$OLD_DIR/geoip"
  BACKUP_DIR="$OLD_DIR/backups"
  NEW_DIR="$OLD_DIR/new"
  run movable_entries
  [ "$status" -eq 0 ]
  moved=$(printf '%s\n' "${lines[@]##*/}" | sort | tr '\n' ' ')
  [ "$moved" = ".env docker-compose.yml matomo.env notes.txt scripts " ]
}

@test "movable_entries moves everything when data lives outside OLD_DIR" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  mkdir -p "$OLD_DIR"
  touch "$OLD_DIR/docker-compose.yml" "$OLD_DIR/msmtpd.env"
  ENV_VALUES[MATOMO_DB_DIR]=/data/matomo/db
  ENV_VALUES[MATOMO_WEB_DIR]=/data/matomo/web
  ENV_VALUES[MATOMO_GEOIP_DIR]=/data/matomo/geoip-updater
  BACKUP_DIR=/data/matomo/backups
  NEW_DIR=/opt/matomo-new
  run movable_entries
  [ "${#lines[@]}" -eq 2 ]
}

@test "check_dirs rejects a non-empty NEW_DIR" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  NEW_DIR="$BATS_TEST_TMPDIR/new"
  mkdir -p "$OLD_DIR" "$NEW_DIR"
  touch "$OLD_DIR/docker-compose.yml" "$NEW_DIR/something"
  run check_dirs
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW_DIR is not empty"* ]]
}

@test "check_dirs requires exactly one compose file" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  NEW_DIR="$BATS_TEST_TMPDIR/new"
  mkdir -p "$OLD_DIR"
  run check_dirs
  [ "$status" -eq 1 ]
  touch "$OLD_DIR/docker-compose.yml" "$OLD_DIR/compose.yml"
  run check_dirs
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one compose file"* ]]
}

@test "check_dirs refuses an existing _old_ directory and NEW_DIR == OLD_DIR" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  mkdir -p "$OLD_DIR/_old_"
  touch "$OLD_DIR/docker-compose.yml"
  NEW_DIR="$BATS_TEST_TMPDIR/new"
  run check_dirs
  [ "$status" -eq 1 ]
  [[ "$output" == *"_old_ already exists"* ]]
  rmdir "$OLD_DIR/_old_"
  NEW_DIR="$OLD_DIR"
  run check_dirs
  [ "$status" -eq 1 ]
}

@test "check_dirs accepts a valid layout and finds the compose file" {
  OLD_DIR="$BATS_TEST_TMPDIR/old"
  NEW_DIR="$BATS_TEST_TMPDIR/new"
  mkdir -p "$OLD_DIR"
  touch "$OLD_DIR/docker-compose.yml"
  check_dirs
  [ "$OLD_COMPOSE" = "docker-compose.yml" ]
}

@test "parse_args takes two directories and the options" {
  parse_args --yes --matomo-image reg/m:5 /old /new
  [ "$ASSUME_YES" = true ]
  [ "$DRY_RUN" = false ]
  [ "$MATOMO_IMAGE_OVERRIDE" = "reg/m:5" ]
  [ "$OLD_DIR" = /old ]
  [ "$NEW_DIR" = /new ]
}

@test "parse_args validates --start-period and --wait-timeout" {
  parse_args --start-period 3600s --wait-timeout 4000 /old /new
  [ "$START_PERIOD_OVERRIDE" = 3600s ]
  [ "$WAIT_TIMEOUT_OVERRIDE" = 4000 ]
  run parse_args --start-period soon /old /new
  [ "$status" -ne 0 ]
  run parse_args --wait-timeout 10m /old /new
  [ "$status" -ne 0 ]
}

@test "parse_args rejects missing or extra arguments" {
  run parse_args /old
  [ "$status" -ne 0 ]
  run parse_args /a /b /c
  [ "$status" -ne 0 ]
  run parse_args --unknown /a /b
  [ "$status" -ne 0 ]
}

@test "duration_to_seconds understands s, m and h" {
  [ "$(duration_to_seconds 1800s)" = 1800 ]
  [ "$(duration_to_seconds 30m)" = 1800 ]
  [ "$(duration_to_seconds 2h)" = 7200 ]
  run duration_to_seconds 10
  [ "$status" -ne 0 ]
}

@test "image_repository strips tags and digests but keeps registry ports" {
  [ "$(image_repository ghcr.io/hlidacstatu/matomo:5)" = ghcr.io/hlidacstatu/matomo ]
  [ "$(image_repository localhost:5000/matomo:broken)" = localhost:5000/matomo ]
  [ "$(image_repository localhost:5000/matomo)" = localhost:5000/matomo ]
  [ "$(image_repository mariadb@sha256:abc)" = mariadb ]
  [ "$(image_repository redis:4.0-alpine)" = redis ]
}

@test "set_env_file_value replaces only the given key" {
  file="$BATS_TEST_TMPDIR/.env"
  printf "%s\n" "MARIADB_IMAGE='mariadb@sha256:abc'" "MARIADB_IMAGE_OTHER='x'" "TZ='UTC'" >"$file"
  set_env_file_value "$file" MARIADB_IMAGE mariadb:10.11
  [ "$(cat "$file")" = "$(printf "%s\n" "MARIADB_IMAGE='mariadb:10.11'" "MARIADB_IMAGE_OTHER='x'" "TZ='UTC'")" ]
  run set_env_file_value "$file" TZ "it's"
  [ "$status" -ne 0 ]
}

@test "ini_has_plugin finds activated plugins only" {
  ini="$BATS_TEST_TMPDIR/config.ini.php"
  printf '%s\n' '[Plugins]' 'Plugins[] = "CoreHome"' 'Plugins[] = "QueuedTracking"' \
    '[PluginsInstalled]' 'PluginsInstalled[] = "CustomAlerts"' >"$ini"
  ini_has_plugin "$ini" QueuedTracking
  run ini_has_plugin "$ini" CustomAlerts
  [ "$status" -ne 0 ]
}

@test "db_fingerprint_sql escapes the prefix and includes versions only when installed" {
  run db_fingerprint_sql matomo_ true
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT LIKE 'matomo\_archive\_%'"* ]]
  [[ "$output" == *'`matomo_option`'* ]]
  [[ "$output" == *"LIKE 'version\_%'"* ]]
  run db_fingerprint_sql matomo_ false
  [[ "$output" != *option* ]]
  run db_fingerprint_sql "x'; DROP" true
  [ "$status" -ne 0 ]
}
