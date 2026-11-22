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

@test "db_fingerprint_sql covers index type and order" {
  run db_fingerprint_sql matomo_ true
  [[ "$output" == *"index_type"* ]]
  [[ "$output" == *"collation"* ]]
}

@test "db_fingerprint_sql escapes the prefix and includes versions only when installed" {
  run db_fingerprint_sql matomo_ true
  [ "$status" -eq 0 ]
  # only the rotating monthly archive tables are excluded
  [[ "$output" == *"NOT LIKE 'matomo\_archive\_numeric\_%'"* ]]
  [[ "$output" == *"NOT LIKE 'matomo\_archive\_blob\_%'"* ]]
  [[ "$output" != *"NOT LIKE 'matomo\_archive\_%'"* ]]
  [[ "$output" == *"information_schema.statistics"* ]]
  [[ "$output" == *'`matomo_option`'* ]]
  [[ "$output" == *"LIKE 'version\_%'"* ]]
  run db_fingerprint_sql matomo_ false
  [[ "$output" != *option* ]]
  run db_fingerprint_sql "x'; DROP" true
  [ "$status" -ne 0 ]
}

@test "ini_has_plugin and ini_value accept indented lines" {
  ini="$BATS_TEST_TMPDIR/config.ini.php"
  printf '%s\n' '  [database]' '  password = "secret"' ' [Plugins]' '  Plugins[] = "QueuedTracking"' >"$ini"
  ini_has_plugin "$ini" QueuedTracking
  [ "$(ini_value "$ini" database password)" = secret ]
}

@test "db_restore_needed trusts a fingerprint match only for the same Matomo version" {
  run db_restore_needed abc abc true
  [ "$status" -eq 1 ]
  # Matomo upgraded: always restore
  run db_restore_needed abc abc false
  [ "$status" -eq 0 ]
  # schema changed
  run db_restore_needed abc def true
  [ "$status" -eq 0 ]
  # fingerprint could not be computed after the switch
  run db_restore_needed abc "" true
  [ "$status" -eq 0 ]
}

@test "has_enough_space works in integers and fails closed" {
  free=$(free_bytes "$BATS_TEST_TMPDIR")
  [[ $free =~ ^[0-9]+$ ]]
  has_enough_space "$BATS_TEST_TMPDIR" 1 >/dev/null
  # more than any disk: 2^62 bytes
  run has_enough_space "$BATS_TEST_TMPDIR" 4611686018427387904
  [ "$status" -ne 0 ]
  run has_enough_space "$BATS_TEST_TMPDIR" 3.14573e+09
  [ "$status" -ne 0 ]
  run has_enough_space "$BATS_TEST_TMPDIR" ""
  [ "$status" -ne 0 ]
  run has_enough_space "$BATS_TEST_TMPDIR/missing" 1
  [ "$status" -ne 0 ]
}

@test "conflicting_shared_images reports a reference shared by different image IDs" {
  run conflicting_shared_images <<<"$(printf '%s\n' 'matomo crazymax/matomo:latest sha256:a' \
    'cron crazymax/matomo:latest sha256:b' 'db mariadb:10.4 sha256:c' 'redis redis:4 sha256:c')"
  [ "$output" = docker.io/crazymax/matomo:latest ]
  run conflicting_shared_images <<<"$(printf '%s\n' 'matomo m:1 sha256:a' 'cron m:1 sha256:a')"
  [ -z "$output" ]
}

@test "normalize_reference makes Docker reference aliases equal" {
  [ "$(normalize_reference crazymax/matomo)" = docker.io/crazymax/matomo:latest ]
  [ "$(normalize_reference docker.io/crazymax/matomo:latest)" = docker.io/crazymax/matomo:latest ]
  [ "$(normalize_reference redis:4)" = docker.io/library/redis:4 ]
  [ "$(normalize_reference ghcr.io/x/matomo)" = ghcr.io/x/matomo:latest ]
  [ "$(normalize_reference localhost:5000/m:1)" = localhost:5000/m:1 ]
  [ "$(normalize_reference mariadb@sha256:ab)" = docker.io/library/mariadb@sha256:ab ]
  run conflicting_shared_images <<<"$(printf '%s\n' 'matomo crazymax/matomo sha256:old' \
    'cron docker.io/crazymax/matomo:latest sha256:new')"
  [ "$output" = docker.io/crazymax/matomo:latest ]
}

@test "is_missing_tag_error separates a missing tag from network errors" {
  is_missing_tag_error 'Error response from daemon: failed to resolve reference "ghcr.io/x/matomo:5.0.0": ghcr.io/x/matomo:5.0.0: not found'
  is_missing_tag_error 'Error response from daemon: manifest for ghcr.io/x/matomo:5.0.0 not found: manifest unknown: manifest unknown'
  run is_missing_tag_error 'Error response from daemon: Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
  [ "$status" -ne 0 ]
  run is_missing_tag_error 'toomanyrequests: You have reached your pull rate limit'
  [ "$status" -ne 0 ]
}

@test "cleanup_new_dir empties a pre-existing NEW_DIR and removes a created one" {
  NEW_DIR="$BATS_TEST_TMPDIR/existing"
  mkdir "$NEW_DIR"
  touch "$NEW_DIR/.env" "$NEW_DIR/compose.yml"
  NEW_DIR_WRITTEN=true NEW_DIR_CREATED=false
  cleanup_new_dir
  [ -d "$NEW_DIR" ]
  [ -z "$(ls -A "$NEW_DIR")" ]
  NEW_DIR_CREATED=true
  cleanup_new_dir
  [ ! -e "$NEW_DIR" ]
  # nothing written by this run: nothing touched
  NEW_DIR="$BATS_TEST_TMPDIR/other"
  mkdir "$NEW_DIR"
  touch "$NEW_DIR/keep"
  NEW_DIR_WRITTEN=false
  cleanup_new_dir
  [ -f "$NEW_DIR/keep" ]
}

@test "finalize_env switches all image lines at once or leaves .env untouched (exit 3)" {
  # The only external call is the `docker compose config` validation.
  docker() { return 0; }
  NEW_DIR="$BATS_TEST_TMPDIR/new"
  mkdir "$NEW_DIR"
  printf "%s\n" "MATOMO_IMAGE='ghcr.io/x/matomo:5.14.1'" "MARIADB_IMAGE='mariadb@sha256:1'" "TZ='UTC'" >"$NEW_DIR/.env"
  FINAL_IMAGES=([MATOMO_IMAGE]=ghcr.io/x/matomo:5 [MARIADB_IMAGE]=mariadb:10.11)
  finalize_env
  grep -qx "MATOMO_IMAGE='ghcr.io/x/matomo:5'" "$NEW_DIR/.env"
  grep -qx "MARIADB_IMAGE='mariadb:10.11'" "$NEW_DIR/.env"
  grep -qx "TZ='UTC'" "$NEW_DIR/.env"
  grep -q '^# .*matomo-update' "$NEW_DIR/.env"
  [ "$(stat -c %a "$NEW_DIR/.env")" = "600" ]

  before=$(cat "$NEW_DIR/.env")
  FINAL_IMAGES=([MATOMO_IMAGE]=ghcr.io/x/matomo:6 [MARIADB_IMAGE]="it's")
  run finalize_env
  [ "$status" -eq 3 ]
  [ "$(cat "$NEW_DIR/.env")" = "$before" ]
  # the temporary copy with the password is gone
  [ -z "$(find "$NEW_DIR" -name '.env.final.*')" ]
  # a failing logger does not change the exit code
  log() { return 1; }
  run finalize_env
  [ "$status" -eq 3 ]
}
