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
# If any step fails or the run is interrupted (signal, unexpected error), the
# previous images are re-tagged locally, the config is restored, the database
# is restored from the step 1 dump when the Matomo version changed or the
# schema fingerprint changed (otherwise - e.g. a security rebuild of the same
# Matomo version - the live data is kept, see db_restore_needed in
# server/lib/db.sh), the stack is started again and the failed image IDs are recorded in
# STATE_DIR so that later runs do not retry the same broken image.
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
# Dumps and config archives hold credentials.
umask 077

REQUIRED_CONFIG=(
  COMPOSE_DIR APP_SERVICE CRON_SERVICE DB_SERVICE
  BACKUP_DIR BACKUP_RETENTION_DAYS STATE_DIR LOG_FILE LOCK_FILE
  WAIT_TIMEOUT_SECONDS HEALTH_URL HEALTH_RETRIES HEALTH_TIMEOUT_SECONDS
  IMAGE_PRUNE_UNTIL
)
REQUIRED_COMMANDS=(docker jq flock gzip curl find setsid)
# Standard OCI label set by the image build to the Matomo version.
VERSION_LABEL=org.opencontainers.image.version

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# One JSON line per event on stdout (journald).
LOG_STDOUT_FORMAT=json

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=server/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=server/lib/db.sh
source "$SCRIPT_DIR/lib/db.sh"
# shellcheck source=server/lib/matomo-config.sh
source "$SCRIPT_DIR/lib/matomo-config.sh"
# shellcheck source=server/lib/host.sh
source "$SCRIPT_DIR/lib/host.sh"
# Matomo's table prefix when config.ini.php does not set one (Matomo default).
MATOMO_DEFAULT_TABLE_PREFIX=matomo_

# Parallel arrays describing the services of the stack (filled by collect_state).
SERVICES=()
REFS=()
OLD_IDS=()
NEW_IDS=()
CHANGED=()
DB_BACKUP_FILE=""
CONFIG_BACKUP_FILE=""
PRE_DB_FINGERPRINT=""
MATOMO_INSTALLED=false
TABLE_PREFIX=$MATOMO_DEFAULT_TABLE_PREFIX
# idle | backup | applying | rolling_back - drives the EXIT trap.
PHASE=idle

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

# WAIT_TIMEOUT_SECONDS must outlast the Matomo start period of the stack,
# otherwise a long database migration is cut off and rolled back.
check_start_period() {
  local value seconds
  value=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?MATOMO_START_PERIOD[[:space:]]*=[[:space:]]*//p' "$COMPOSE_DIR/.env" 2>/dev/null |
    tail -n1 | tr -d "'\"") || true
  [[ -n $value ]] || return 0
  if [[ ! $value =~ ^([0-9]+)([smh])$ ]]; then
    log error config_invalid "MATOMO_START_PERIOD in .env is not a duration like 1800s" value "$value"
    exit 2
  fi
  seconds=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in m) seconds=$((seconds * 60)) ;; h) seconds=$((seconds * 3600)) ;; esac
  if ((WAIT_TIMEOUT_SECONDS <= seconds)); then
    log error config_invalid "WAIT_TIMEOUT_SECONDS must be longer than MATOMO_START_PERIOD" \
      wait_timeout "$WAIT_TIMEOUT_SECONDS" start_period "$value"
    exit 2
  fi
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
  # A rollback re-tags each reference to one image ID; services sharing a
  # reference (matomo and cron) must therefore run the same image.
  local i conflicts
  conflicts=$(for i in "${!SERVICES[@]}"; do
    [[ -z ${OLD_IDS[$i]} ]] || echo "${SERVICES[$i]} ${REFS[$i]} ${OLD_IDS[$i]}"
  done | conflicting_shared_images)
  if [[ -n $conflicts ]]; then
    log error state_invalid "services sharing an image reference run different images; recreate them first" \
      images "$conflicts" hint "docker compose up -d --pull never --force-recreate"
    exit 2
  fi
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
    log error pull_failed "docker compose pull failed (network or registry problem?)" output "$output"
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

# Fails when the backup filesystem has less free space than the database
# holds (an uncompressed logical dump is about that size).
check_backup_space() {
  local need free
  need=$(db_size_sql | docker compose exec -T "$DB_SERVICE" sh -c "$DB_CLIENT_SNIPPET") || return 1
  if ! free=$(has_enough_space "$BACKUP_DIR" "$need"); then
    log error backup_failed "not enough free space for the database dump (or it cannot be measured)" \
      dir "$BACKUP_DIR" free_bytes "$free" database_bytes "$need"
    return 1
  fi
}

# Dumps the Matomo database and archives /data/config of the app container.
create_backup() {
  local app_cid app_old_id
  check_backup_space || return 1
  DB_BACKUP_FILE="$BACKUP_DIR/matomo-db-$RUN_ID.sql.gz"
  CONFIG_BACKUP_FILE="$BACKUP_DIR/matomo-config-$RUN_ID.tar.gz"

  # A failed dump must not leave a partial file that fills the disk.
  if ! docker compose exec -T "$DB_SERVICE" sh -c "$DB_DUMP_SNIPPET" | gzip >"$DB_BACKUP_FILE.partial"; then
    rm -f "$DB_BACKUP_FILE.partial"
    log error backup_failed "database dump failed"
    return 1
  fi
  if ! gzip -t "$DB_BACKUP_FILE.partial" ||
    ! gzip -dc "$DB_BACKUP_FILE.partial" | tail -n1 | grep -q '^-- Dump completed'; then
    rm -f "$DB_BACKUP_FILE.partial"
    log error backup_failed "database dump is incomplete"
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
    rm -f "$CONFIG_BACKUP_FILE.partial"
    log error backup_failed "config backup failed"
    return 1
  fi
  mv "$CONFIG_BACKUP_FILE.partial" "$CONFIG_BACKUP_FILE"

  read_matomo_config "$CONFIG_BACKUP_FILE"
  if ! PRE_DB_FINGERPRINT=$(db_fingerprint_sql "$TABLE_PREFIX" "$MATOMO_INSTALLED" |
    docker compose exec -T "$DB_SERVICE" sh -c "$DB_CLIENT_SNIPPET") || [[ -z $PRE_DB_FINGERPRINT ]]; then
    log error backup_failed "cannot compute the database schema fingerprint"
    return 1
  fi
  log info backup_created "backup created" db_backup "$DB_BACKUP_FILE" config_backup "$CONFIG_BACKUP_FILE" \
    schema_fingerprint "$PRE_DB_FINGERPRINT"
}

# read_matomo_config CONFIG_ARCHIVE - sets MATOMO_INSTALLED and TABLE_PREFIX
# from config.ini.php inside the config backup.
read_matomo_config() {
  local ini prefix
  ini=$(mktemp)
  if tar -xzOf "$1" config/config.ini.php >"$ini" 2>/dev/null && grep -qE '^[[:space:]]*\[database\]' "$ini"; then
    MATOMO_INSTALLED=true
    prefix=$(ini_value "$ini" database tables_prefix)
    [[ -z $prefix ]] || TABLE_PREFIX=$prefix
  fi
  rm -f "$ini"
}

# docker compose for the stack (the script runs in COMPOSE_DIR); a command
# name for compose_up_wait.
stack_compose() {
  docker compose "$@"
}

# Starts all services except cron and waits until they are healthy/running.
start_services() {
  local -a svcs
  mapfile -t svcs < <(services_without_cron)
  compose_up_wait stack_compose "$WAIT_TIMEOUT_SECONDS" "${svcs[@]}"
}

# The cron sidecar has no healthcheck: compose_up_wait checks that it runs.
start_cron() {
  compose_up_wait stack_compose "$WAIT_TIMEOUT_SECONDS" "$CRON_SERVICE"
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

  if docker compose exec -T "$APP_SERVICE" sh -c 'grep -qE "^[[:space:]]*\[database\]" /data/config/config.ini.php' 2>/dev/null; then
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

# Prints the Matomo version label of an image (empty when it has none).
image_version() {
  local v
  v=$(docker image inspect --format "{{ index .Config.Labels \"$VERSION_LABEL\" }}" "$1" 2>/dev/null) || v=""
  [[ $v == "<no value>" ]] && v=""
  printf '%s' "$v"
}

restore_backup() {
  local app_cid app_old_id i old_version new_version same_version=false db_restored=false
  if ! compose_up_wait stack_compose "$WAIT_TIMEOUT_SECONDS" "$DB_SERVICE"; then
    log error restore_failed "database service did not start"
    return 1
  fi
  i=$(service_index "$APP_SERVICE")
  old_version=$(image_version "${OLD_IDS[$i]}")
  new_version=$(image_version "${NEW_IDS[$i]}")
  [[ -n $old_version && $old_version == "$new_version" ]] && same_version=true
  local post
  post=$(db_fingerprint_sql "$TABLE_PREFIX" "$MATOMO_INSTALLED" |
    docker compose exec -T "$DB_SERVICE" sh -c "$DB_CLIENT_SNIPPET") || post=""
  if db_restore_needed "$PRE_DB_FINGERPRINT" "$post" "$same_version"; then
    log warn db_restore "restoring the dump (Matomo version or schema changed); data tracked since the backup is discarded" \
      matomo_from "$old_version" matomo_to "$new_version" before "$PRE_DB_FINGERPRINT" after "$post"
    # setsid: the docker CLI installs its own signal handlers (it would not
    # inherit the ignored signals), so keep it out of reach of a Ctrl+C.
    if ! gzip -dc "$DB_BACKUP_FILE" | setsid docker compose exec -T "$DB_SERVICE" sh -c "$DB_CLIENT_SNIPPET"; then
      log error restore_failed "database restore failed" file "$DB_BACKUP_FILE"
      return 1
    fi
    db_restored=true
  else
    log info db_unchanged "same Matomo version and schema, keeping all data (no restore)" matomo_version "$old_version"
  fi
  app_cid=$(docker compose ps -a -q "$APP_SERVICE" | head -n1)
  app_old_id=${OLD_IDS[$(service_index "$APP_SERVICE")]}
  # config/ is replaced as a whole (files added by the new version go too);
  # the current tree is kept aside until the archive is extracted.
  # shellcheck disable=SC2016
  if ! docker run --rm -i --volumes-from "$app_cid" --entrypoint sh "$app_old_id" -c '
      set -e
      aside=/data/config.before-rollback
      rm -rf "$aside"
      mv /data/config "$aside"
      if tar -C /data -xzf -; then rm -rf "$aside"; else rm -rf /data/config; mv "$aside" /data/config; exit 1; fi' \
    <"$CONFIG_BACKUP_FILE"; then
    log error restore_failed "config restore failed" file "$CONFIG_BACKUP_FILE"
    return 1
  fi
  log info restore_succeeded "config restored, database restored or unchanged" \
    db_restored "$db_restored" db_backup "$DB_BACKUP_FILE"
}

# Reverts to the previously running images and restores the backup. Always exits 1.
rollback() {
  local svc i
  PHASE=rolling_back
  # A second signal (or systemd's stop) must not cut a restore in half.
  trap '' INT TERM HUP
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
    log warn rollback_succeeded "previous version is running again"
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

# Shell variables take precedence over .env during compose interpolation;
# remove every COMPOSE_* variable and every key the stack's .env defines
# (except this script's own configuration, e.g. COMPOSE_DIR).
clean_compose_environment() {
  local var
  while IFS= read -r var; do
    [[ " ${REQUIRED_CONFIG[*]} " == *" $var "* ]] || unset "$var"
  done < <({ compgen -e | grep -E '^COMPOSE_'; [[ ! -f .env ]] || dotenv_keys .env; } || true)
}

# EXIT trap: an interruption must not leave the stack half updated.
on_exit() {
  case $PHASE in
    backup)
      restore_tags
      log error interrupted "interrupted before any container was replaced, previous images re-tagged"
      ;;
    applying)
      log error interrupted "interrupted during the update, rolling back"
      rollback
      ;;
  esac
}

main() {
  if [[ $# -ne 1 ]]; then
    log error usage "usage: matomo-update.sh CONFIG_FILE"
    exit 2
  fi
  load_server_config "$1"
  require_commands
  check_start_period
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log warn locked "another update is already running"
    exit 0
  fi

  cd "$COMPOSE_DIR"
  clean_compose_environment
  trap on_exit EXIT
  trap 'exit 130' INT TERM HUP
  log info run_started "checking for updates" compose_dir "$COMPOSE_DIR"

  collect_state
  pull_images
  detect_changes

  if ((${#CHANGED[@]} == 0)); then
    log info no_update "all services are up to date"
    cleanup
    exit 0
  fi

  PHASE=backup
  if app_or_db_changed && ! create_backup; then
    restore_tags
    PHASE=idle
    log error update_aborted "update aborted before any change, previous images re-tagged"
    exit 1
  fi

  PHASE=applying
  if apply_update; then
    PHASE=idle
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
