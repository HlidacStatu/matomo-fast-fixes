#!/usr/bin/env bash
# matomo-update.sh - safely updates the Matomo docker compose stack.
#
# Intended to run unattended from a systemd timer (see server/systemd/).
# It is a no-op unless `docker compose pull` brings a new image for at least
# one service. When something changed:
#
#   1. a database dump and a tarball of Matomo's /data/config are taken
#      (only when the app, cron or db image changed),
#   2. the cron sidecar is stopped so archiving does not run during migrations,
#   3. all other services are recreated and awaited until healthy; Matomo runs
#      `core:update` (DB migrations) on start,
#   4. the stack is verified: HTTP check, Matomo version == image label,
#      `core:update` reports nothing pending,
#   5. cron is started again.
#
# If any step fails, the previous images are re-tagged locally, the database
# and config are restored from the backup taken in step 1 (migrations may
# already have run), the stack is started again and the failed image IDs are
# recorded in STATE_DIR so that later runs do not retry the same broken image.
# A new upstream image (different ID) is tried normally.
#
# Every event is written as one JSON line to stdout (journald) and LOG_FILE.
#
# Usage: matomo-update.sh CONFIG_FILE
# Exit codes: 0 = nothing to do or update succeeded,
#             1 = update failed (rolled back or rollback failed - see log),
#             2 = invalid configuration or environment.
# Configuration variables are assigned by sourcing CONFIG_FILE:
# shellcheck disable=SC2153
set -euo pipefail

REQUIRED_CONFIG=(
  COMPOSE_DIR APP_SERVICE CRON_SERVICE DB_SERVICE
  BACKUP_DIR BACKUP_RETENTION_DAYS STATE_DIR LOG_FILE LOCK_FILE
  WAIT_TIMEOUT_SECONDS HEALTH_URL HEALTH_RETRIES HEALTH_TIMEOUT_SECONDS
  IMAGE_PRUNE_UNTIL
)
REQUIRED_COMMANDS=(docker jq flock gzip curl find)
# Standard OCI label set by the image build to the Matomo version.
VERSION_LABEL=org.opencontainers.image.version

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# Parallel arrays describing the services of the stack (filled by collect_state).
SERVICES=()
REFS=()
OLD_IDS=()
NEW_IDS=()
CHANGED=()
DB_BACKUP_FILE=""
CONFIG_BACKUP_FILE=""

# log LEVEL EVENT MESSAGE [KEY VALUE]...
log() {
  local level=$1 event=$2 message=$3
  shift 3
  local fields='{}'
  while (($# >= 2)); do
    fields=$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$fields")
    shift 2
  done
  local line
  line=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg level "$level" \
    --arg event "$event" \
    --arg message "$message" \
    --arg run_id "$RUN_ID" \
    --argjson fields "$fields" \
    '{ts: $ts, level: $level, event: $event, message: $message, run_id: $run_id} + $fields')
  printf '%s\n' "$line"
  if [[ -n ${LOG_FILE:-} ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

# Loads CONFIG_FILE and fails fast (exit 2) when any required key is missing.
load_server_config() {
  local file=$1 key
  local -a missing=()
  if [[ ! -f $file ]]; then
    log error config_invalid "config file not found" file "$file"
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  for key in "${REQUIRED_CONFIG[@]}"; do
    [[ -n ${!key:-} ]] || missing+=("$key")
  done
  if ((${#missing[@]} > 0)); then
    log error config_invalid "missing required config keys" file "$file" missing "${missing[*]}"
    exit 2
  fi
  local numeric
  for numeric in BACKUP_RETENTION_DAYS WAIT_TIMEOUT_SECONDS HEALTH_RETRIES HEALTH_TIMEOUT_SECONDS; do
    if [[ ! ${!numeric} =~ ^[0-9]+$ ]]; then
      log error config_invalid "value must be a non-negative integer" key "$numeric" value "${!numeric}"
      exit 2
    fi
  done
}

require_commands() {
  local cmd
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log error environment_invalid "required command not found" command "$cmd"
      exit 2
    fi
  done
  if ! docker compose version >/dev/null 2>&1; then
    log error environment_invalid "docker compose plugin is not available"
    exit 2
  fi
}

# --- state helpers -----------------------------------------------------------

# Prints the index of SERVICE in SERVICES, fails when not found.
service_index() {
  local i
  for i in "${!SERVICES[@]}"; do
    if [[ ${SERVICES[$i]} == "$1" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# Succeeds when SERVICE is in the CHANGED list.
is_changed() {
  local svc
  for svc in "${CHANGED[@]}"; do
    [[ $svc == "$1" ]] && return 0
  done
  return 1
}

local_image_id() {
  docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# Prints the image ID of SERVICE's container (empty when it has no container).
container_image_id() {
  local cid
  cid=$(docker compose ps -a -q "$1" | head -n1)
  [[ -n $cid ]] || return 0
  docker inspect --format '{{.Image}}' "$cid"
}

blocked_file() {
  echo "$STATE_DIR/blocked-images"
}

# is_blocked REF IMAGE_ID - succeeds when this image previously failed to deploy.
is_blocked() {
  [[ -f $(blocked_file) ]] && grep -qxF "$1 $2" "$(blocked_file)"
}

block_image() {
  is_blocked "$1" "$2" || printf '%s %s\n' "$1" "$2" >>"$(blocked_file)"
}

# Services in start order, without the cron sidecar.
services_without_cron() {
  local svc
  for svc in "${SERVICES[@]}"; do
    [[ $svc == "$CRON_SERVICE" ]] || echo "$svc"
  done
}

app_or_db_changed() {
  is_changed "$APP_SERVICE" || is_changed "$CRON_SERVICE" || is_changed "$DB_SERVICE"
}

app_changed() {
  is_changed "$APP_SERVICE" || is_changed "$CRON_SERVICE"
}

# --- steps -------------------------------------------------------------------

# Records every service with its image reference and the image ID its
# container currently runs.
collect_state() {
  local config svc ref
  config=$(docker compose config --format json)
  while IFS= read -r svc; do
    ref=$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$config")
    if [[ -z $ref ]]; then
      log warn service_skipped "service has no image reference" service "$svc"
      continue
    fi
    SERVICES+=("$svc")
    REFS+=("$ref")
    OLD_IDS+=("$(container_image_id "$svc")")
  done < <(docker compose config --services)
  local required
  for required in "$APP_SERVICE" "$CRON_SERVICE" "$DB_SERVICE"; do
    if ! service_index "$required" >/dev/null; then
      log error config_invalid "service not found in compose project" service "$required"
      exit 2
    fi
  done
}

pull_images() {
  local output
  if ! output=$(docker compose pull --quiet 2>&1); then
    log error pull_failed "docker compose pull failed (registry login?)" output "$output"
    exit 1
  fi
}

# Compares pulled images with running containers and fills NEW_IDS / CHANGED.
# Images that previously failed are re-tagged back to the running image.
detect_changes() {
  local i svc ref old new
  for i in "${!SERVICES[@]}"; do
    svc=${SERVICES[$i]}
    ref=${REFS[$i]}
    old=${OLD_IDS[$i]}
    new=$(local_image_id "$ref")
    NEW_IDS[i]=$new
    if [[ -z $old ]]; then
      log warn service_not_created "service has no container, nothing to update" service "$svc"
    elif [[ -z $new ]]; then
      log error image_missing "image not available after pull" service "$svc" image "$ref"
      exit 1
    elif [[ $new == "$old" ]]; then
      continue
    elif is_blocked "$ref" "$new"; then
      docker tag "$old" "$ref"
      log warn image_blocked "skipping image that failed to deploy before" service "$svc" image "$ref" image_id "$new"
    else
      CHANGED+=("$svc")
      log info image_changed "new image available" service "$svc" image "$ref" old_id "$old" new_id "$new"
    fi
  done
}

# Puts the previously running image IDs back on their tags.
restore_tags() {
  local svc i
  for svc in "${CHANGED[@]}"; do
    i=$(service_index "$svc")
    docker tag "${OLD_IDS[$i]}" "${REFS[$i]}"
  done
}

# Dumps the Matomo database and archives /data/config of the app container.
create_backup() {
  local app_cid app_old_id
  DB_BACKUP_FILE="$BACKUP_DIR/matomo-db-$RUN_ID.sql.gz"
  CONFIG_BACKUP_FILE="$BACKUP_DIR/matomo-config-$RUN_ID.tar.gz"

  # Variables are expanded inside the db container (MYSQL_* / MARIADB_* of the image).
  # shellcheck disable=SC2016
  if ! docker compose exec -T "$DB_SERVICE" sh -c '
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec mariadb-dump \
        --single-transaction --quick --add-drop-database \
        -u"${MARIADB_USER:-$MYSQL_USER}" \
        --databases "${MARIADB_DATABASE:-$MYSQL_DATABASE}"' |
    gzip >"$DB_BACKUP_FILE.partial"; then
    log error backup_failed "database dump failed"
    return 1
  fi
  if ! gzip -t "$DB_BACKUP_FILE.partial" ||
    ! gzip -dc "$DB_BACKUP_FILE.partial" | tail -n1 | grep -q '^-- Dump completed'; then
    log error backup_failed "database dump is incomplete" file "$DB_BACKUP_FILE.partial"
    return 1
  fi
  mv "$DB_BACKUP_FILE.partial" "$DB_BACKUP_FILE"

  # The config is read through the old container's volumes with the old image,
  # so the backup does not depend on the freshly pulled image.
  app_cid=$(docker compose ps -a -q "$APP_SERVICE" | head -n1)
  app_old_id=${OLD_IDS[$(service_index "$APP_SERVICE")]}
  if ! docker run --rm --volumes-from "$app_cid" --entrypoint tar "$app_old_id" \
    -C /data -czf - config >"$CONFIG_BACKUP_FILE.partial" ||
    ! gzip -t "$CONFIG_BACKUP_FILE.partial"; then
    log error backup_failed "config backup failed"
    return 1
  fi
  mv "$CONFIG_BACKUP_FILE.partial" "$CONFIG_BACKUP_FILE"
  log info backup_created "backup created" db_backup "$DB_BACKUP_FILE" config_backup "$CONFIG_BACKUP_FILE"
}

# Starts all services except cron and waits until they are healthy/running.
start_services() {
  local -a svcs
  mapfile -t svcs < <(services_without_cron)
  docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" "${svcs[@]}"
}

start_cron() {
  docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" "$CRON_SERVICE"
}

# Verifies that Matomo answers, runs the expected version and has no pending
# database migrations.
verify_app() {
  local ref expected actual output
  if ! curl -fsS -o /dev/null --max-time "$HEALTH_TIMEOUT_SECONDS" \
    --retry "$HEALTH_RETRIES" --retry-all-errors --retry-delay 2 "$HEALTH_URL"; then
    log error verify_failed "HTTP check failed" url "$HEALTH_URL"
    return 1
  fi

  ref=${REFS[$(service_index "$APP_SERVICE")]}
  expected=$(docker image inspect --format "{{ index .Config.Labels \"$VERSION_LABEL\" }}" "$ref")
  # shellcheck disable=SC2016
  if ! actual=$(docker compose exec -T "$APP_SERVICE" php -r \
    'require "/var/www/matomo/core/Version.php"; echo \Piwik\Version::VERSION;'); then
    log error verify_failed "cannot read Matomo version"
    return 1
  fi
  if [[ -n $expected && $expected != "<no value>" && $actual != "$expected" ]]; then
    log error verify_failed "Matomo version does not match image label" expected "$expected" actual "$actual"
    return 1
  fi

  if docker compose exec -T "$APP_SERVICE" sh -c 'grep -q "^\[database\]" /data/config/config.ini.php' 2>/dev/null; then
    if ! output=$(docker compose exec -T "$APP_SERVICE" console core:update --yes --no-interaction 2>&1); then
      log error verify_failed "core:update failed" output "$output"
      return 1
    fi
  else
    log warn verify_partial "Matomo is not installed yet, skipping core:update check"
  fi
  log info verify_succeeded "stack verified" matomo_version "$actual"
}

apply_update() {
  if ! docker compose stop "$CRON_SERVICE"; then
    log error update_step_failed "cannot stop cron sidecar"
    return 1
  fi
  if ! start_services; then
    log error update_step_failed "services did not become healthy" timeout "$WAIT_TIMEOUT_SECONDS"
    return 1
  fi
  verify_app || return 1
  if ! start_cron; then
    log error update_step_failed "cron sidecar did not start"
    return 1
  fi
}

restore_backup() {
  local app_cid app_old_id
  if ! docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" "$DB_SERVICE"; then
    log error restore_failed "database service did not start"
    return 1
  fi
  # shellcheck disable=SC2016
  if ! gzip -dc "$DB_BACKUP_FILE" | docker compose exec -T "$DB_SERVICE" sh -c '
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec mariadb -u"${MARIADB_USER:-$MYSQL_USER}"'; then
    log error restore_failed "database restore failed" file "$DB_BACKUP_FILE"
    return 1
  fi
  app_cid=$(docker compose ps -a -q "$APP_SERVICE" | head -n1)
  app_old_id=${OLD_IDS[$(service_index "$APP_SERVICE")]}
  if ! docker run --rm -i --volumes-from "$app_cid" --entrypoint tar "$app_old_id" \
    -C /data -xzf - <"$CONFIG_BACKUP_FILE"; then
    log error restore_failed "config restore failed" file "$CONFIG_BACKUP_FILE"
    return 1
  fi
  log info restore_succeeded "database and config restored" db_backup "$DB_BACKUP_FILE"
}

# Reverts to the previously running images and restores the backup. Always exits 1.
rollback() {
  local svc i
  log warn rollback_started "rolling back to previous images" services "${CHANGED[*]}"
  for svc in "${CHANGED[@]}"; do
    i=$(service_index "$svc")
    docker tag "${OLD_IDS[$i]}" "${REFS[$i]}"
    block_image "${REFS[$i]}" "${NEW_IDS[$i]}"
    log warn image_blocked "image marked as failed" service "$svc" image "${REFS[$i]}" image_id "${NEW_IDS[$i]}"
  done

  if ! docker compose stop "$CRON_SERVICE" "$APP_SERVICE"; then
    log error rollback_failed "cannot stop app services, manual intervention required"
    exit 1
  fi
  if app_changed && ! restore_backup; then
    log error rollback_failed "restore failed, manual intervention required" \
      db_backup "$DB_BACKUP_FILE" config_backup "$CONFIG_BACKUP_FILE"
    exit 1
  fi
  if start_services && verify_app && start_cron; then
    log warn rollback_succeeded "previous version is running again; data written during the update window was discarded"
  else
    log error rollback_failed "stack is not healthy after rollback, manual intervention required" \
      db_backup "$DB_BACKUP_FILE" config_backup "$CONFIG_BACKUP_FILE"
  fi
  exit 1
}

cleanup() {
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'matomo-db-*.sql.gz' -o -name 'matomo-config-*.tar.gz' -o -name '*.partial' \) \
    -mtime +"$BACKUP_RETENTION_DAYS" -delete
  docker image prune -f --filter "until=$IMAGE_PRUNE_UNTIL" >/dev/null
}

main() {
  if [[ $# -ne 1 ]]; then
    log error usage "usage: matomo-update.sh CONFIG_FILE"
    exit 2
  fi
  load_server_config "$1"
  require_commands
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log warn locked "another update is already running"
    exit 0
  fi

  cd "$COMPOSE_DIR"
  log info run_started "checking for updates" compose_dir "$COMPOSE_DIR"

  collect_state
  pull_images
  detect_changes

  if ((${#CHANGED[@]} == 0)); then
    log info no_update "all services are up to date"
    cleanup
    exit 0
  fi

  if app_or_db_changed && ! create_backup; then
    restore_tags
    log error update_aborted "update aborted before any change, previous images re-tagged"
    exit 1
  fi

  if apply_update; then
    log info update_succeeded "stack updated" services "${CHANGED[*]}"
    cleanup
    exit 0
  fi

  log error update_failed "update failed" services "${CHANGED[*]}"
  rollback
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
