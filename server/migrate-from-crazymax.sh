#!/usr/bin/env bash
# migrate-from-crazymax.sh - moves a running crazymax/matomo compose stack to
# this repository's server/compose.yml. Data stays where it is.
#
# Usage: migrate-from-crazymax.sh [options] OLD_DIR NEW_DIR
#
#   OLD_DIR  directory with the old compose file (docker-compose.yml, ...) and
#            its env files; the stack must be running
#   NEW_DIR  directory for the new compose.yml/.env (must be empty or missing)
#
#   --yes                     do not ask before the switch (non-interactive use)
#   --dry-run                 run all checks, show the generated configuration,
#                             change nothing
#   --matomo-image IMAGE      deploy IMAGE instead of MATOMO_IMAGE from .env.example
#   --start-period DURATION   MATOMO_START_PERIOD written to the new .env (e.g. 3600s)
#                             instead of the .env.example value
#   --wait-timeout SECONDS    how long the switch may wait for a healthy stack
#                             instead of WAIT_TIMEOUT_SECONDS from matomo-update.env.example
#
# What it does:
#   1. checks (no downtime): all six services run (db, redis, msmtpd,
#      geoip-updater, matomo, cron), only bind mounts hold data, Matomo's
#      config.ini.php uses the same database credentials, Matomo major
#      version matches, Docker Engine is recent enough,
#   2. generates NEW_DIR from the *running* containers (environment minus
#      image defaults, bind mounts, published port). The values are read from
#      the containers, not from the old files, so env_file/environment/shell
#      variables are all carried over exactly. MariaDB keeps its running
#      major.minor line, so the data directory is never upgraded or downgraded
#      by the migration,
#   3. pulls the new images, then asks for confirmation,
#   4. stops cron, dumps the database and archives Matomo's config,
#   5. moves every file of OLD_DIR except data directories into OLD_DIR/_old_
#      and starts the new stack in place of the old one (same project name,
#      containers are recreated) - downtime starts and ends here,
#   6. verifies the new stack (health, HTTP, Matomo version, core:update),
#   7. installs and enables the systemd timer for matomo-update.sh.
#
# If step 5 or 6 fails, the migration is rolled back automatically: the new
# containers are removed, the files are moved back from _old_, the database
# and config are restored from the step 4 backup and the old stack is started.
#
# Exit codes: 0 migrated, 1 failed and rolled back (or nothing was changed),
#             2 rollback failed (manual intervention, see log),
#             3 migrated but the timer could not be installed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=server/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/../scripts/lib/version.sh"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_STDOUT_FORMAT=text

ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
UPDATE_ENV_EXAMPLE="$SCRIPT_DIR/matomo-update.env.example"
NEW_COMPOSE_TEMPLATE="$SCRIPT_DIR/compose.yml"
INSTALL_TIMER="$SCRIPT_DIR/install-timer.sh"

# Service names are fixed: Matomo's config refers to them as host names
# (database "db", Redis "redis", SMTP "msmtpd").
SERVICES=(db redis msmtpd geoip-updater matomo cron)
COMPOSE_FILE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)
OLD_SUBDIR=_old_
# compose.yml uses the healthcheck option start_interval (Docker Engine 25).
MIN_DOCKER_MAJOR=25
VERSION_LABEL=org.opencontainers.image.version
# Environment set by compose.yml itself, therefore not copied into env files.
CRON_ONLY_KEYS=(TZ SIDECAR_CRON CRON_ARCHIVE ARCHIVE_OPTIONS)
REQUIRED_COMMANDS=(docker jq curl gzip tar realpath)

ASSUME_YES=false
DRY_RUN=false
MATOMO_IMAGE_OVERRIDE=""
START_PERIOD_OVERRIDE=""
WAIT_TIMEOUT_OVERRIDE=""
OLD_DIR=""
NEW_DIR=""
OLD_COMPOSE=""
OLD_PROJECT=""
BACKUP_DIR=""
DB_BACKUP_FILE=""
CONFIG_BACKUP_FILE=""
MATOMO_INSTALLED=false
SWITCH_STARTED_AT=0
DRY_RUN_DIR=""
declare -gA ENV_VALUES=()
declare -gA OLD_CID=()

# --- helpers -------------------------------------------------------------------

fail() {
  log error "$1" "$2" "${@:3}"
  exit 1
}

usage() {
  sed -n '4,/^# What it does/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 1
}

# env_file_value FILE KEY - value of KEY in a KEY=VALUE file (no shell parsing).
env_file_value() {
  local line
  grep -qE "^$2=" "$1" || return 1
  line=$(grep -E "^$2=" "$1" | tail -n1)
  printf '%s\n' "${line#*=}"
}

# Keys of a KEY=VALUE file, in file order.
env_file_keys() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1
}

old_compose() {
  (cd "$OLD_DIR" && docker compose -f "$OLD_COMPOSE" "$@")
}

new_compose() {
  (cd "$NEW_DIR" && docker compose "$@")
}

# Environment of a container minus the defaults of its image, as a JSON object.
container_env_diff() {
  local cid=$1 image cenv ienv
  image=$(docker inspect --format '{{.Image}}' "$cid")
  cenv=$(docker inspect --format '{{json .Config.Env}}' "$cid")
  ienv=$(docker image inspect --format '{{json .Config.Env}}' "$image")
  jq -n --argjson c "$cenv" --argjson i "${ienv:-[]}" '
    [$c[] | select(. as $e | ($i // []) | index($e) | not)
      | capture("^(?<k>[^=]+)=(?<v>.*)$"; "s") | {(.k): .v}] | add // {}'
}

# Full environment of a container as a JSON object.
container_env() {
  docker inspect --format '{{json .Config.Env}}' "$1" |
    jq '[.[] | capture("^(?<k>[^=]+)=(?<v>.*)$"; "s") | {(.k): .v}] | add // {}'
}

# Source of the bind mount at DESTINATION in container CID (empty if none).
bind_source() {
  docker inspect --format '{{json .Mounts}}' "$1" |
    jq -r --arg d "$2" '.[] | select(.Destination == $d and .Type == "bind") | .Source'
}

# check_mounts SERVICE CID DESTINATION... - every mount must be one of the
# expected bind mounts; anything else would silently be lost by the migration.
check_mounts() {
  local svc=$1 cid=$2
  shift 2
  local unexpected
  unexpected=$(docker inspect --format '{{json .Mounts}}' "$cid" | jq -r --args '
    .[] | select((.Type != "bind") or (.Destination | IN($ARGS.positional[]) | not))
        | "\(.Type):\(.Source // .Name)->\(.Destination)"' "$@")
  if [[ -n $unexpected ]]; then
    fail unsupported_mount "service has mounts the new compose.yml does not carry over" \
      service "$svc" mounts "$(tr '\n' ' ' <<<"$unexpected")"
  fi
}

# ini_value FILE SECTION KEY - value from Matomo's config.ini.php.
ini_value() {
  awk -v section="[$2]" -v key="$3" '
    { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
    /^\[/ { in_section = ($0 == section); next }
    in_section {
      line = $0; sub(/^[ \t]+/, "", line)
      n = index(line, "="); if (n == 0) next
      k = substr(line, 1, n - 1); sub(/[ \t]+$/, "", k)
      if (k != key) next
      v = substr(line, n + 1); sub(/^[ \t]+/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}

# write_env_file FILE JSON_OBJECT [EXCLUDED_KEY]...
# Values are written single-quoted, which compose reads literally.
write_env_file() {
  local file=$1 json=$2
  shift 2
  local excluded
  excluded=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  local bad
  bad=$(jq -r --argjson x "$excluded" --arg q "'" 'to_entries[] | select(.key | IN($x[]) | not)
    | select((.value | contains($q)) or (.value | contains("\n"))) | .key' <<<"$json")
  [[ -z $bad ]] || fail unsupported_value "values with single quotes or newlines cannot be migrated" keys "$bad"
  jq -r --argjson x "$excluded" --arg q "'" 'to_entries | sort_by(.key)[] | select(.key | IN($x[]) | not)
    | "\(.key)=\($q)\(.value)\($q)"' <<<"$json" >"$file"
  chmod 600 "$file"
}

# is_inside PATH DIR - PATH equals DIR or lies below it.
is_inside() {
  [[ $1 == "$2" || $1 == "$2"/* ]]
}

# Prints the entries of OLD_DIR that are moved to _old_: everything except
# data directories (and their parents), backups, NEW_DIR and _old_ itself.
movable_entries() {
  local entry path keep keep_paths=()
  for keep in "${ENV_VALUES[MATOMO_DB_DIR]}" "${ENV_VALUES[MATOMO_WEB_DIR]}" \
    "${ENV_VALUES[MATOMO_GEOIP_DIR]}" "$BACKUP_DIR" "$NEW_DIR"; do
    keep_paths+=("$(realpath -m "$keep")")
  done
  shopt -s dotglob nullglob
  for entry in "$OLD_DIR"/*; do
    path=$(realpath -m "$entry")
    [[ ${entry##*/} == "$OLD_SUBDIR" ]] && continue
    local skip=false
    for keep in "${keep_paths[@]}"; do
      if is_inside "$keep" "$path"; then
        skip=true
        break
      fi
    done
    $skip || printf '%s\n' "$entry"
  done
  shopt -u dotglob nullglob
}

# --- steps -------------------------------------------------------------------

parse_args() {
  while (($# > 0)); do
    case $1 in
      --yes) ASSUME_YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --matomo-image)
        [[ $# -ge 2 ]] || usage
        MATOMO_IMAGE_OVERRIDE=$2
        shift
        ;;
      --start-period)
        [[ $# -ge 2 && $2 =~ ^[0-9]+[smh]$ ]] || usage
        START_PERIOD_OVERRIDE=$2
        shift
        ;;
      --wait-timeout)
        [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || usage
        WAIT_TIMEOUT_OVERRIDE=$2
        shift
        ;;
      -h | --help) usage ;;
      -*) usage ;;
      *)
        if [[ -z $OLD_DIR ]]; then
          OLD_DIR=$1
        elif [[ -z $NEW_DIR ]]; then
          NEW_DIR=$1
        else
          usage
        fi
        ;;
    esac
    shift
  done
  [[ -n $OLD_DIR && -n $NEW_DIR ]] || usage
}

check_environment() {
  local cmd version
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || fail environment_invalid "required command not found" command "$cmd"
  done
  docker compose version >/dev/null 2>&1 || fail environment_invalid "docker compose plugin is not available"
  version=$(docker version --format '{{.Server.Version}}')
  ((${version%%.*} >= MIN_DOCKER_MAJOR)) ||
    fail environment_invalid "Docker Engine is too old" version "$version" required "$MIN_DOCKER_MAJOR+"
  if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
    fail environment_invalid "must run as root (moves files, installs the systemd timer)"
  fi
}

check_dirs() {
  local name found=()
  [[ -d $OLD_DIR ]] || fail invalid_argument "OLD_DIR does not exist" dir "$OLD_DIR"
  OLD_DIR=$(realpath "$OLD_DIR")
  NEW_DIR=$(realpath -m "$NEW_DIR")
  [[ $NEW_DIR != "$OLD_DIR" ]] || fail invalid_argument "NEW_DIR must differ from OLD_DIR"
  ! is_inside "$NEW_DIR" "$OLD_DIR/$OLD_SUBDIR" || fail invalid_argument "NEW_DIR must not be inside $OLD_SUBDIR"
  if [[ -e $NEW_DIR ]] && [[ -n $(ls -A "$NEW_DIR") ]]; then
    fail invalid_argument "NEW_DIR is not empty" dir "$NEW_DIR"
  fi
  [[ ! -e $OLD_DIR/$OLD_SUBDIR ]] || fail invalid_argument "$OLD_SUBDIR already exists in OLD_DIR" dir "$OLD_DIR/$OLD_SUBDIR"
  for name in "${COMPOSE_FILE_NAMES[@]}"; do
    [[ -f $OLD_DIR/$name ]] && found+=("$name")
  done
  ((${#found[@]} == 1)) || fail invalid_argument "OLD_DIR must contain exactly one compose file" found "${found[*]:-none}"
  OLD_COMPOSE=${found[0]}
}

# Reads the running old stack and fills ENV_VALUES and the env files' content.
inspect_old_stack() {
  local config svc cid state
  config=$(old_compose config --format json) || fail old_stack_invalid "cannot read old compose file"
  OLD_PROJECT=$(jq -r .name <<<"$config")

  local actual expected
  actual=$(jq -r '.services | keys[]' <<<"$config" | sort | tr '\n' ' ')
  expected=$(printf '%s\n' "${SERVICES[@]}" | sort | tr '\n' ' ')
  [[ $actual == "$expected" ]] ||
    fail old_stack_invalid "old compose must have exactly the crazymax services" found "$actual" expected "$expected"

  for svc in "${SERVICES[@]}"; do
    cid=$(old_compose ps -q "$svc" | head -n1)
    [[ -n $cid ]] || fail old_stack_invalid "service has no container, start the old stack first" service "$svc"
    state=$(docker inspect --format '{{.State.Status}}' "$cid")
    [[ $state == running ]] || fail old_stack_invalid "service is not running" service "$svc" state "$state"
    OLD_CID[$svc]=$cid
  done

  # Data locations.
  local db_dir web_dir geoip_dir
  db_dir=$(bind_source "${OLD_CID[db]}" /var/lib/mysql)
  web_dir=$(bind_source "${OLD_CID[matomo]}" /data)
  geoip_dir=$(bind_source "${OLD_CID[matomo]}" /data/geoip)
  [[ -n $db_dir ]] || fail unsupported_mount "db: /var/lib/mysql must be a bind mount"
  [[ -n $web_dir ]] || fail unsupported_mount "matomo: /data must be a bind mount"
  [[ -n $geoip_dir ]] || fail unsupported_mount "matomo: /data/geoip must be a bind mount"
  check_mounts db "${OLD_CID[db]}" /var/lib/mysql
  check_mounts matomo "${OLD_CID[matomo]}" /data /data/geoip
  check_mounts cron "${OLD_CID[cron]}" /data /data/geoip
  check_mounts geoip-updater "${OLD_CID[geoip-updater]}" /data
  [[ $(bind_source "${OLD_CID[cron]}" /data) == "$web_dir" && $(bind_source "${OLD_CID[cron]}" /data/geoip) == "$geoip_dir" ]] ||
    fail unsupported_mount "cron must mount the same directories as matomo"
  [[ $(bind_source "${OLD_CID[geoip-updater]}" /data) == "$geoip_dir" ]] ||
    fail unsupported_mount "geoip-updater must write to the directory matomo mounts at /data/geoip"
  ENV_VALUES[MATOMO_DB_DIR]=$db_dir
  ENV_VALUES[MATOMO_WEB_DIR]=$web_dir
  ENV_VALUES[MATOMO_GEOIP_DIR]=$geoip_dir
  BACKUP_DIR="$(dirname "$web_dir")/backups"

  # Published port.
  local ports
  ports=$(jq -c '.services.matomo.ports // []' <<<"$config")
  [[ $(jq 'length' <<<"$ports") == 1 && $(jq -r '.[0].target' <<<"$ports") == 8000 && $(jq -r '.[0].host_ip // ""' <<<"$ports") == "" ]] ||
    fail old_stack_invalid "matomo must publish exactly port 8000 on all interfaces" ports "$ports"
  ENV_VALUES[MATOMO_PUBLISHED_PORT]=$(jq -r '.[0].published' <<<"$ports")

  # Environment.
  local db_env app_env cron_env app_diff cron_diff
  db_env=$(container_env "${OLD_CID[db]}")
  ENV_VALUES[MYSQL_DATABASE]=$(jq -r '.MARIADB_DATABASE // .MYSQL_DATABASE // empty' <<<"$db_env")
  ENV_VALUES[MYSQL_USER]=$(jq -r '.MARIADB_USER // .MYSQL_USER // empty' <<<"$db_env")
  ENV_VALUES[MYSQL_PASSWORD]=$(jq -r '.MARIADB_PASSWORD // .MYSQL_PASSWORD // empty' <<<"$db_env")
  local key
  for key in MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD; do
    [[ -n ${ENV_VALUES[$key]} ]] || fail old_stack_invalid "db has no $key (or MARIADB_ equivalent)"
  done

  app_env=$(container_env "${OLD_CID[matomo]}")
  cron_env=$(container_env "${OLD_CID[cron]}")
  ENV_VALUES[TZ]=$(jq -r '.TZ // empty' <<<"$app_env")
  [[ -n ${ENV_VALUES[TZ]} ]] || fail old_stack_invalid "cannot determine TZ of the matomo container"
  ENV_VALUES[CRON_ARCHIVE]=$(jq -r '.CRON_ARCHIVE // empty' <<<"$cron_env")
  ENV_VALUES[ARCHIVE_OPTIONS]=$(jq -r '.ARCHIVE_OPTIONS // empty' <<<"$cron_env")
  [[ -n ${ENV_VALUES[CRON_ARCHIVE]} ]] || fail old_stack_invalid "cron has no CRON_ARCHIVE schedule"
  [[ -n ${ENV_VALUES[ARCHIVE_OPTIONS]} ]] || fail old_stack_invalid "cron has no ARCHIVE_OPTIONS"

  app_diff=$(container_env_diff "${OLD_CID[matomo]}")
  cron_diff=$(container_env_diff "${OLD_CID[cron]}")
  local cron_only
  cron_only=$(printf '%s\n' "${CRON_ONLY_KEYS[@]}" | jq -R . | jq -s .)
  local mismatch
  mismatch=$(jq -rn --argjson a "$app_diff" --argjson c "$cron_diff" --argjson x "$cron_only" '
    ($a | del(.[$x[]])) as $a | ($c | del(.[$x[]])) as $c
    | (($a | keys) + ($c | keys) | unique)[] | select($a[.] != $c[.])')
  [[ -z $mismatch ]] ||
    fail old_stack_invalid "matomo and cron have different environment; the new compose shares one matomo.env" keys "$(tr '\n' ' ' <<<"$mismatch")"
  MATOMO_ENV_JSON=$app_diff
  MSMTPD_ENV_JSON=$(container_env_diff "${OLD_CID[msmtpd]}")
  GEOIP_ENV_JSON=$(container_env_diff "${OLD_CID[geoip-updater]}")

  # Versions.
  # shellcheck disable=SC2016
  OLD_MATOMO_VERSION=$(docker exec "${OLD_CID[matomo]}" php -r \
    'require "/var/www/matomo/core/Version.php"; echo \Piwik\Version::VERSION;') ||
    fail old_stack_invalid "cannot read the Matomo version of the old stack"
  local db_version
  # shellcheck disable=SC2016
  db_version=$(docker exec "${OLD_CID[db]}" sh -c '
      client=mariadb; command -v mariadb >/dev/null 2>&1 || client=mysql
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$client" -N \
        -u"${MARIADB_USER:-$MYSQL_USER}" -e "SELECT VERSION()"') ||
    fail old_stack_invalid "cannot query the MariaDB version with the db credentials"
  [[ $db_version == *MariaDB* ]] || fail old_stack_invalid "only MariaDB is supported" version "$db_version"
  OLD_DB_VERSION=${db_version%%-*}
  ENV_VALUES[MARIADB_IMAGE]="mariadb:$(cut -d. -f1-2 <<<"$OLD_DB_VERSION")"

  # Matomo's own database settings must match, otherwise backups are empty.
  local ini="$web_dir/config/config.ini.php"
  if [[ -f $ini ]] && grep -q '^\[database\]' "$ini"; then
    MATOMO_INSTALLED=true
    local host user dbname
    host=$(ini_value "$ini" database host)
    user=$(ini_value "$ini" database username)
    dbname=$(ini_value "$ini" database dbname)
    if [[ $host != db || $user != "${ENV_VALUES[MYSQL_USER]}" || $dbname != "${ENV_VALUES[MYSQL_DATABASE]}" ]]; then
      fail credentials_mismatch "config.ini.php does not use the db service credentials" \
        ini_host "$host" ini_username "$user" ini_dbname "$dbname" \
        db_user "${ENV_VALUES[MYSQL_USER]}" db_database "${ENV_VALUES[MYSQL_DATABASE]}"
    fi
  fi

  log info old_stack_ok "old stack inspected" project "$OLD_PROJECT" compose_file "$OLD_COMPOSE" \
    matomo_version "$OLD_MATOMO_VERSION" mariadb_version "$OLD_DB_VERSION" installed "$MATOMO_INSTALLED" \
    db_dir "$db_dir" web_dir "$web_dir" geoip_dir "$geoip_dir"
}

# Values that do not come from the old stack are taken from .env.example.
fill_defaults_from_example() {
  local key
  for key in REDIS_IMAGE MSMTPD_IMAGE GEOIP_UPDATER_IMAGE MATOMO_START_PERIOD MATOMO_IMAGE; do
    ENV_VALUES[$key]=$(env_file_value "$ENV_EXAMPLE" "$key") || fail config_invalid "$key missing in .env.example"
  done
  [[ -z $MATOMO_IMAGE_OVERRIDE ]] || ENV_VALUES[MATOMO_IMAGE]=$MATOMO_IMAGE_OVERRIDE
  [[ -z $START_PERIOD_OVERRIDE ]] || ENV_VALUES[MATOMO_START_PERIOD]=$START_PERIOD_OVERRIDE
  ENV_VALUES[COMPOSE_PROJECT_NAME]=$OLD_PROJECT

  WAIT_TIMEOUT_SECONDS=${WAIT_TIMEOUT_OVERRIDE:-$(env_file_value "$UPDATE_ENV_EXAMPLE" WAIT_TIMEOUT_SECONDS)}
  HEALTH_RETRIES=$(env_file_value "$UPDATE_ENV_EXAMPLE" HEALTH_RETRIES)
  HEALTH_TIMEOUT_SECONDS=$(env_file_value "$UPDATE_ENV_EXAMPLE" HEALTH_TIMEOUT_SECONDS)
  HEALTH_URL="http://127.0.0.1:${ENV_VALUES[MATOMO_PUBLISHED_PORT]}/"
}

# Writes compose.yml, .env and the env files into DIR.
generate_config() {
  local dir=$1 key
  mkdir -p "$dir"
  cp "$NEW_COMPOSE_TEMPLATE" "$dir/compose.yml"
  : >"$dir/.env"
  chmod 600 "$dir/.env"
  while IFS= read -r key; do
    [[ -n ${ENV_VALUES[$key]+set} ]] || fail config_invalid "no value for .env key" key "$key"
    [[ ${ENV_VALUES[$key]} != *"'"* ]] || fail unsupported_value "value contains a single quote" key "$key"
    printf "%s='%s'\n" "$key" "${ENV_VALUES[$key]}" >>"$dir/.env"
  done < <(env_file_keys "$ENV_EXAMPLE")
  write_env_file "$dir/matomo.env" "$MATOMO_ENV_JSON" "${CRON_ONLY_KEYS[@]}"
  write_env_file "$dir/msmtpd.env" "$MSMTPD_ENV_JSON" TZ
  write_env_file "$dir/geoip-updater.env" "$GEOIP_ENV_JSON" TZ
  (cd "$dir" && docker compose config --quiet) || fail config_invalid "generated configuration is invalid" dir "$dir"
}

check_new_images() {
  local dir=$1 new_version
  if ! (cd "$dir" && docker compose pull --quiet); then
    fail pull_failed "cannot pull the new images"
  fi
  new_version=$(docker image inspect --format "{{ index .Config.Labels \"$VERSION_LABEL\" }}" "${ENV_VALUES[MATOMO_IMAGE]}")
  is_stable_version "$new_version" || fail image_invalid "new Matomo image has no version label" image "${ENV_VALUES[MATOMO_IMAGE]}"
  [[ ${new_version%%.*} == "${OLD_MATOMO_VERSION%%.*}" ]] ||
    fail version_mismatch "Matomo major versions differ; upgrade the major version separately" old "$OLD_MATOMO_VERSION" new "$new_version"
  if version_gt "$OLD_MATOMO_VERSION" "$new_version"; then
    fail version_mismatch "the new image is older than the running Matomo" old "$OLD_MATOMO_VERSION" new "$new_version"
  fi
  NEW_MATOMO_VERSION=$new_version
  log info images_ready "new images pulled" matomo_image "${ENV_VALUES[MATOMO_IMAGE]}" \
    matomo_version "$new_version" mariadb_image "${ENV_VALUES[MARIADB_IMAGE]}"
}

print_plan() {
  local entries
  entries=$(movable_entries | sed "s|^$OLD_DIR/||" | tr '\n' ' ')
  cat <<EOF

Migration plan
  old stack:      $OLD_DIR/$OLD_COMPOSE (project $OLD_PROJECT)
  new stack:      $NEW_DIR/compose.yml (same project name, containers are recreated)
  Matomo:         $OLD_MATOMO_VERSION -> $NEW_MATOMO_VERSION (${ENV_VALUES[MATOMO_IMAGE]})
  MariaDB:        $OLD_DB_VERSION -> ${ENV_VALUES[MARIADB_IMAGE]} (same release line)
  data (stays):   ${ENV_VALUES[MATOMO_DB_DIR]}
                  ${ENV_VALUES[MATOMO_WEB_DIR]}
                  ${ENV_VALUES[MATOMO_GEOIP_DIR]}
  backup to:      $BACKUP_DIR
  moved to $OLD_SUBDIR: $entries
  downtime:       from stopping the old containers until the new stack is healthy
EOF
}

print_generated_env() {
  local dir=$1
  echo
  echo "Generated $dir/.env (password masked):"
  sed -E "s/^(MYSQL_PASSWORD=).*/\1'********'/" "$dir/.env" | sed 's/^/  /'
  echo "Generated env files: matomo.env ($(jq length <<<"$MATOMO_ENV_JSON") keys from the running container)," \
    "msmtpd.env, geoip-updater.env"
}

confirm() {
  $ASSUME_YES && return 0
  [[ -r /dev/tty ]] || fail confirmation_required "no terminal to confirm on; use --yes"
  local answer
  read -r -p "Proceed with the switch (short downtime)? [y/N] " answer </dev/tty
  [[ $answer == y || $answer == Y || $answer == yes ]] || fail aborted "migration aborted by the user, nothing was changed"
}

create_backup() {
  mkdir -p "$BACKUP_DIR" || return 1
  DB_BACKUP_FILE="$BACKUP_DIR/matomo-db-$RUN_ID-pre-migration.sql.gz"
  CONFIG_BACKUP_FILE="$BACKUP_DIR/matomo-config-$RUN_ID-pre-migration.tar.gz"
  # shellcheck disable=SC2016
  if ! docker exec "${OLD_CID[db]}" sh -c '
      dump=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || dump=mysqldump
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$dump" \
        --single-transaction --quick --add-drop-database \
        -u"${MARIADB_USER:-$MYSQL_USER}" --databases "${MARIADB_DATABASE:-$MYSQL_DATABASE}"' |
    gzip >"$DB_BACKUP_FILE"; then
    return 1
  fi
  gzip -dc "$DB_BACKUP_FILE" | tail -n1 | grep -q '^-- Dump completed' || return 1
  local tables
  tables=$(gzip -dc "$DB_BACKUP_FILE" | grep -c '^CREATE TABLE' || true)
  if $MATOMO_INSTALLED && ((tables == 0)); then
    log error backup_empty "Matomo is installed but the dump contains no tables"
    return 1
  fi
  tar -C "${ENV_VALUES[MATOMO_WEB_DIR]}" -czf "$CONFIG_BACKUP_FILE" config || return 1
  log info backup_created "backup created" db_backup "$DB_BACKUP_FILE" tables "$tables" config_backup "$CONFIG_BACKUP_FILE"
}

move_old_files() {
  local entry
  mkdir "$OLD_DIR/$OLD_SUBDIR" || return 1
  while IFS= read -r entry; do
    mv "$entry" "$OLD_DIR/$OLD_SUBDIR/" || return 1
  done < <(movable_entries)
  log info old_files_moved "old files moved" dir "$OLD_DIR/$OLD_SUBDIR" \
    files "$(find "$OLD_DIR/$OLD_SUBDIR" -mindepth 1 -maxdepth 1 -printf '%f ')"
}

restore_old_files() {
  local entry
  [[ -d $OLD_DIR/$OLD_SUBDIR ]] || return 0
  shopt -s dotglob nullglob
  for entry in "$OLD_DIR/$OLD_SUBDIR"/*; do
    mv "$entry" "$OLD_DIR/" || return 1
  done
  shopt -u dotglob nullglob
  rmdir "$OLD_DIR/$OLD_SUBDIR" || return 1
}

verify_new_stack() {
  local actual output
  if ! curl -fsS -o /dev/null --max-time "$HEALTH_TIMEOUT_SECONDS" \
    --retry "$HEALTH_RETRIES" --retry-all-errors --retry-delay 2 "$HEALTH_URL"; then
    log error verify_failed "HTTP check failed" url "$HEALTH_URL"
    return 1
  fi
  # shellcheck disable=SC2016
  actual=$(new_compose exec -T matomo php -r \
    'require "/var/www/matomo/core/Version.php"; echo \Piwik\Version::VERSION;') || return 1
  if [[ $actual != "$NEW_MATOMO_VERSION" ]]; then
    log error verify_failed "unexpected Matomo version" expected "$NEW_MATOMO_VERSION" actual "$actual"
    return 1
  fi
  if $MATOMO_INSTALLED; then
    if ! output=$(new_compose exec -T matomo console core:update --yes --no-interaction 2>&1); then
      log error verify_failed "core:update failed" output "$output"
      return 1
    fi
  fi
  log info verify_succeeded "new stack verified" matomo_version "$actual"
}

# Waits until the old db container accepts connections (the old compose file
# usually has no healthcheck).
wait_for_old_db() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  # shellcheck disable=SC2016
  until old_compose exec -T db sh -c '
      admin=mariadb-admin; command -v mariadb-admin >/dev/null 2>&1 || admin=mysqladmin
      exec "$admin" ping -h 127.0.0.1 --silent' >/dev/null 2>&1; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

rollback() {
  log warn rollback_started "rolling back to the old stack"
  new_compose down --remove-orphans || log warn rollback_step "removing new containers reported an error"
  if ! restore_old_files; then
    log error rollback_failed "cannot move files back from $OLD_SUBDIR" dir "$OLD_DIR/$OLD_SUBDIR"
    exit 2
  fi
  if ! old_compose up -d db || ! wait_for_old_db; then
    log error rollback_failed "old database does not start" db_backup "$DB_BACKUP_FILE"
    exit 2
  fi
  # shellcheck disable=SC2016
  if ! gzip -dc "$DB_BACKUP_FILE" | old_compose exec -T db sh -c '
      client=mariadb; command -v mariadb >/dev/null 2>&1 || client=mysql
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$client" -u"${MARIADB_USER:-$MYSQL_USER}"'; then
    log error rollback_failed "database restore failed" db_backup "$DB_BACKUP_FILE"
    exit 2
  fi
  if ! tar -C "${ENV_VALUES[MATOMO_WEB_DIR]}" -xzf "$CONFIG_BACKUP_FILE"; then
    log error rollback_failed "config restore failed" config_backup "$CONFIG_BACKUP_FILE"
    exit 2
  fi
  if ! old_compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS"; then
    log error rollback_failed "old stack does not become healthy" compose_file "$OLD_DIR/$OLD_COMPOSE"
    exit 2
  fi
  log warn rollback_succeeded "old stack is running again with the pre-migration data" \
    new_dir "$NEW_DIR" downtime_seconds "$((SECONDS - SWITCH_STARTED_AT))"
  exit 1
}

switch() {
  if ! old_compose stop cron; then
    fail switch_failed "cannot stop the old cron sidecar"
  fi
  if ! create_backup; then
    old_compose start cron || true
    fail backup_failed "backup failed, nothing was changed (cron restarted)" db_backup "$DB_BACKUP_FILE"
  fi

  SWITCH_STARTED_AT=$SECONDS
  log info downtime_started "replacing the old containers"
  if ! move_old_files; then
    log error switch_failed "cannot move old files"
    rollback
  fi
  if ! new_compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS"; then
    log error switch_failed "new stack did not become healthy"
    rollback
  fi
  if ! verify_new_stack; then
    rollback
  fi
  log info downtime_ended "new stack is serving" downtime_seconds "$((SECONDS - SWITCH_STARTED_AT))"
}

install_timer() {
  if ! "$INSTALL_TIMER" "$NEW_DIR" "$BACKUP_DIR" "$HEALTH_URL"; then
    log error timer_failed "migration succeeded, but the systemd timer could not be installed" \
      command "$INSTALL_TIMER $NEW_DIR $BACKUP_DIR $HEALTH_URL"
    exit 3
  fi
  log info timer_installed "automatic updates enabled (matomo-update.timer)"
}

print_summary() {
  cat <<EOF

Migration finished
  new stack:        $NEW_DIR (docker compose commands are run from here now)
  old files:        $OLD_DIR/$OLD_SUBDIR
  backups:          $DB_BACKUP_FILE
                    $CONFIG_BACKUP_FILE
  automatic update: systemd timer matomo-update.timer runs
                    $SCRIPT_DIR/matomo-update.sh twice a day
                    (config /etc/matomo-update/matomo-update.env, log in journalctl -u matomo-update)
  migration log:    $LOG_FILE

Recommended follow-up (see MIGRATION.md): set a MariaDB root password,
move to a newer MariaDB LTS in a separate maintenance window.
EOF
}

main() {
  parse_args "$@"
  check_environment
  check_dirs
  log info migration_started "inspecting the old stack" old_dir "$OLD_DIR" new_dir "$NEW_DIR" dry_run "$DRY_RUN"
  inspect_old_stack
  fill_defaults_from_example

  if $DRY_RUN; then
    DRY_RUN_DIR=$(mktemp -d)
    trap 'rm -rf "$DRY_RUN_DIR"' EXIT
    generate_config "$DRY_RUN_DIR"
    check_new_images "$DRY_RUN_DIR"
    print_plan
    print_generated_env "$DRY_RUN_DIR"
    log info dry_run_finished "dry run finished, nothing was changed"
    exit 0
  fi

  generate_config "$NEW_DIR"
  LOG_FILE="$NEW_DIR/migration.log"
  check_new_images "$NEW_DIR"
  print_plan
  print_generated_env "$NEW_DIR"
  confirm
  switch
  install_timer
  log info migration_succeeded "migration finished"
  print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
