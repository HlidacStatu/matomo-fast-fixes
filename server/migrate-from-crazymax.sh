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
#   --dry-run                 run all checks and show the plan; the running stack
#                             and OLD_DIR stay untouched (the Matomo image used
#                             for the switch is pulled)
#   --matomo-image IMAGE      Matomo image the stack tracks after the migration
#                             instead of MATOMO_IMAGE from .env.example
#   --start-period DURATION   MATOMO_START_PERIOD written to the new .env (e.g. 3600s)
#                             instead of the .env.example value
#   --wait-timeout SECONDS    how long the switch (and later matomo-update.sh) may
#                             wait for a healthy stack instead of
#                             WAIT_TIMEOUT_SECONDS from matomo-update.env.example
#
# What it does:
#   The migration changes the orchestration, not the software versions: the
#   switch runs exactly the images the old containers run (MariaDB, Redis,
#   msmtpd, geoip-updater pinned by digest) and this repository's Matomo image
#   of the *same* Matomo version when it is published. The database is then
#   not migrated at all, and a rollback needs no restore. Afterwards .env is
#   pointed at the tracked image lines; matomo-update.sh (systemd timer)
#   upgrades them with its own backup, verification and rollback.
#
#   1. checks (no downtime): all six services run (db, redis, msmtpd,
#      geoip-updater, matomo, cron) with the default network, commands and no
#      extra labels; only bind mounts hold data; Matomo's config.ini.php uses
#      the db service credentials; QueuedTracking is not active; the Matomo
#      major version matches; Docker Engine is recent enough,
#   2. generates NEW_DIR from the *running* containers (environment minus
#      image defaults, bind mounts, published port), so env_file/environment/
#      shell variables are all carried over exactly,
#   3. pulls the Matomo image for the switch, shows the plan and asks,
#   4. stops cron, dumps the database, archives Matomo's config and records a
#      schema fingerprint,
#   5. moves every file of OLD_DIR except data directories into OLD_DIR/_old_
#      and starts the new stack in place of the old one (same project name,
#      containers are recreated) - downtime starts here,
#   6. verifies the new stack (health, HTTP, Matomo version, core:update),
#      then starts cron - downtime ends,
#   7. points .env at the tracked image lines and installs the systemd timer.
#
# If step 5 or 6 fails, or the script is interrupted (signal, unexpected
# error), it rolls back: the new containers are removed, the files are moved
# back from _old_, the old images are re-tagged, the database is restored
# from the step 4 dump only if its schema fingerprint changed, the config is
# restored and the old stack is started and checked.
# A power loss in step 5/6 is not handled automatically: OLD_DIR/_old_ and
# NEW_DIR/migration.log show where it stopped (see MIGRATION.md).
#
# Exit codes: 0 migrated, 1 failed and rolled back (or nothing was changed),
#             2 rollback failed (manual intervention, see log),
#             3 migrated but the timer could not be installed.
set -euo pipefail
# Dumps, archives and generated env files hold credentials.
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=server/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=server/lib/db.sh
source "$SCRIPT_DIR/lib/db.sh"
# shellcheck source=server/lib/matomo-config.sh
source "$SCRIPT_DIR/lib/matomo-config.sh"
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
# Services whose exact old image is kept for the switch (matomo/cron get this
# repository's image instead). Maps service -> .env key.
declare -gA PINNED_IMAGE_KEYS=([db]=MARIADB_IMAGE [redis]=REDIS_IMAGE [msmtpd]=MSMTPD_IMAGE [geoip-updater]=GEOIP_UPDATER_IMAGE)
COMPOSE_FILE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)
OLD_SUBDIR=_old_
# compose.yml uses the healthcheck option start_interval (Docker Engine 25).
MIN_DOCKER_MAJOR=25
VERSION_LABEL=org.opencontainers.image.version
# Timezone the crazymax entrypoint uses when TZ is unset.
CRAZYMAX_TZ_FALLBACK=UTC
# Matomo's table prefix when config.ini.php does not set one (Matomo default).
MATOMO_DEFAULT_TABLE_PREFIX=matomo_
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
TABLE_PREFIX=$MATOMO_DEFAULT_TABLE_PREFIX
PRE_DB_FINGERPRINT=""
SAME_MATOMO_VERSION=false
SWITCH_STARTED_AT=0
DRY_RUN_DIR=""
NEW_DIR_CREATED=false
# idle | backup | switching | rolling_back | switched - drives the EXIT trap.
PHASE=idle
# Values written to .env for the switch.
declare -gA ENV_VALUES=()
# Image values written to .env after a successful switch (tracked lines).
declare -gA FINAL_IMAGES=()
declare -gA OLD_CID=()
declare -gA OLD_IMAGE_ID=()
declare -gA OLD_IMAGE_REF=()

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

# set_env_file_value FILE KEY VALUE - replaces KEY's line, value single-quoted.
set_env_file_value() {
  local file=$1 key=$2 value=$3 tmp
  [[ $value != *"'"* ]] || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  awk -v k="$key" -v line="$key='$value'" 'index($0, k "=") == 1 { print line; next } { print }' "$file" >"$tmp" &&
    mv "$tmp" "$file"
}

# Removes variables that would override compose's own configuration: shell
# variables take precedence over .env during interpolation.
clean_compose_environment() {
  local var
  while IFS= read -r var; do
    unset "$var"
  done < <(compgen -e | grep -E '^COMPOSE_' || true)
}

old_compose() {
  (cd "$OLD_DIR" && clean_compose_environment && docker compose -f "$OLD_COMPOSE" "$@")
}

# compose_in DIR ARGS... - compose in a generated directory, with every .env
# key removed from the environment so that only the generated values apply.
compose_in() {
  local dir=$1 key
  shift
  (
    cd "$dir" || exit 1
    clean_compose_environment
    while IFS= read -r key; do unset "$key"; done < <(env_file_keys "$ENV_EXAMPLE")
    docker compose "$@"
  )
}

new_compose() {
  compose_in "$NEW_DIR" "$@"
}

# duration_to_seconds 1800s|30m|1h - compose/docker duration as seconds.
duration_to_seconds() {
  [[ $1 =~ ^([0-9]+)([smh])$ ]] || return 1
  local n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
  esac
}

# image_repository REF - REF without tag/digest (registry port kept).
image_repository() {
  local ref=${1%%@*} last
  last=${ref##*/}
  if [[ $last == *:* ]]; then
    echo "${ref%:*}"
  else
    echo "$ref"
  fi
}

# Prints the repo digest of IMAGE_ID that belongs to the repository of REF.
pinned_reference() {
  local id=$1 ref=$2 repo
  repo=$(image_repository "$ref")
  [[ $repo == */* ]] || repo="docker.io/library/$repo"
  docker image inspect --format '{{json .RepoDigests}}' "$id" | jq -r --arg r "$repo" '
    .[] | select(. as $d | ($d | startswith($r + "@"))
      or ($d | startswith(($r | sub("^docker\\.io/library/"; "")) + "@"))
      or ($d | startswith(($r | sub("^docker\\.io/"; "")) + "@")))' | head -n1
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

# check_runtime SERVICE CID - settings the new compose.yml does not carry over
# must be at their defaults: network, labels, command and entrypoint.
check_runtime() {
  local svc=$1 cid=$2 image networks labels
  image=$(docker inspect --format '{{.Image}}' "$cid")
  networks=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$cid" | jq -r 'keys | join(" ")')
  [[ $networks == "${OLD_PROJECT}_default" ]] ||
    fail unsupported_setting "service uses networks the new compose.yml does not define" service "$svc" networks "$networks"
  labels=$(jq -rn --argjson c "$(docker inspect --format '{{json .Config.Labels}}' "$cid")" \
    --argjson i "$(docker image inspect --format '{{json .Config.Labels}}' "$image")" '
    ($c // {}) | to_entries[] | select(.key | startswith("com.docker.compose.") | not)
      | select(($i // {})[.key] != .value) | .key')
  [[ -z $labels ]] ||
    fail unsupported_setting "service has labels the new compose.yml does not carry over" service "$svc" labels "$(tr '\n' ' ' <<<"$labels")"
  if [[ $svc != db ]]; then
    [[ $(docker inspect --format '{{json .Config.Cmd}}' "$cid") == "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" &&
      $(docker inspect --format '{{json .Config.Entrypoint}}' "$cid") == "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" ]] ||
      fail unsupported_setting "service overrides the image command or entrypoint" service "$svc"
  fi
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

# db_query CID - runs SQL from stdin in the db container, prints the result.
db_query() {
  docker exec -i "$1" sh -c "$DB_CLIENT_SNIPPET"
}

old_db_cid() {
  old_compose ps -q db | head -n1
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
    OLD_IMAGE_ID[$svc]=$(docker inspect --format '{{.Image}}' "$cid")
    OLD_IMAGE_REF[$svc]=$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$config")
    [[ -n ${OLD_IMAGE_REF[$svc]} ]] || fail old_stack_invalid "service has no image reference" service "$svc"
    check_runtime "$svc" "$cid"
  done

  # Exact old images for the switch.
  for svc in "${!PINNED_IMAGE_KEYS[@]}"; do
    local pinned
    pinned=$(pinned_reference "${OLD_IMAGE_ID[$svc]}" "${OLD_IMAGE_REF[$svc]}")
    [[ -n $pinned ]] || fail old_stack_invalid "running image has no registry digest to pin" \
      service "$svc" image "${OLD_IMAGE_REF[$svc]}"
    ENV_VALUES[${PINNED_IMAGE_KEYS[$svc]}]=$pinned
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
  # The file may have been edited after the container was created.
  local running_port
  running_port=$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${OLD_CID[matomo]}" |
    jq -r '[.["8000/tcp"][]? | select((.HostIp // "") == "" or .HostIp == "0.0.0.0") | .HostPort] | unique | join(",")')
  [[ $running_port == "${ENV_VALUES[MATOMO_PUBLISHED_PORT]}" ]] ||
    fail old_stack_invalid "the running matomo container publishes a different port than the compose file" \
      running "$running_port" file "${ENV_VALUES[MATOMO_PUBLISHED_PORT]}"

  # Settings the new compose.yml cannot express.
  local named stateful
  named=$(jq -r '.services | to_entries[] | select(.value.container_name) | .key' <<<"$config")
  [[ -z $named ]] || fail unsupported_setting "services with container_name are not supported" services "$(tr '\n' ' ' <<<"$named")"
  stateful=$(jq -r '.services | to_entries[] | select(.key == "redis" or .key == "msmtpd")
    | select((.value.volumes // []) | length > 0) | .key' <<<"$config")
  [[ -z $stateful ]] ||
    fail unsupported_setting "redis/msmtpd with volumes (persistent state) are not supported" services "$(tr '\n' ' ' <<<"$stateful")"

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
  if [[ -z ${ENV_VALUES[TZ]} ]]; then
    # Unset TZ means the crazymax entrypoint ran with its own fallback
    # (`TZ=${TZ:-UTC}` in /etc/s6-overlay/scripts/config); keep that behaviour.
    ENV_VALUES[TZ]=$CRAZYMAX_TZ_FALLBACK
    log warn tz_fallback "TZ was not set in the old stack, keeping the crazymax fallback" tz "$CRAZYMAX_TZ_FALLBACK"
  fi
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
  is_stable_version "$OLD_MATOMO_VERSION" || fail old_stack_invalid "unexpected Matomo version" version "$OLD_MATOMO_VERSION"
  local db_version
  db_version=$(db_query "${OLD_CID[db]}" <<<"SELECT VERSION();") ||
    fail old_stack_invalid "cannot query the MariaDB version with the db credentials"
  [[ $db_version == *MariaDB* ]] || fail old_stack_invalid "only MariaDB is supported" version "$db_version"
  OLD_DB_VERSION=${db_version%%-*}

  # Matomo's own database settings must match, otherwise backups are empty.
  local ini="$web_dir/config/config.ini.php"
  if [[ -f $ini ]] && grep -q '^\[database\]' "$ini"; then
    MATOMO_INSTALLED=true
    local host user dbname prefix
    host=$(ini_value "$ini" database host)
    user=$(ini_value "$ini" database username)
    dbname=$(ini_value "$ini" database dbname)
    prefix=$(ini_value "$ini" database tables_prefix)
    [[ -z $prefix ]] || TABLE_PREFIX=$prefix
    if [[ $host != db || $user != "${ENV_VALUES[MYSQL_USER]}" || $dbname != "${ENV_VALUES[MYSQL_DATABASE]}" ]]; then
      fail credentials_mismatch "config.ini.php does not use the db service credentials" \
        ini_host "$host" ini_username "$user" ini_dbname "$dbname" \
        db_user "${ENV_VALUES[MYSQL_USER]}" db_database "${ENV_VALUES[MYSQL_DATABASE]}"
    fi
    # Redis then holds unprocessed tracking requests; recreating the
    # container (no persistence in the crazymax setup) would drop them.
    if ini_has_plugin "$ini" QueuedTracking; then
      fail unsupported_setting "QueuedTracking is active: process and disable the queue first" \
        hint "console queuedtracking:process, then deactivate the plugin or migrate by hand"
    fi
  fi
  db_fingerprint_sql "$TABLE_PREFIX" "$MATOMO_INSTALLED" >/dev/null ||
    fail old_stack_invalid "unsupported table prefix" prefix "$TABLE_PREFIX"

  local non_innodb
  non_innodb=$(db_non_innodb_sql | db_query "${OLD_CID[db]}") || non_innodb=unknown
  if [[ $non_innodb != 0 ]]; then
    log warn non_innodb_tables "the dump is not a consistent snapshot for non-InnoDB tables" count "$non_innodb"
  fi

  log info old_stack_ok "old stack inspected" project "$OLD_PROJECT" compose_file "$OLD_COMPOSE" \
    matomo_version "$OLD_MATOMO_VERSION" mariadb_version "$OLD_DB_VERSION" installed "$MATOMO_INSTALLED" \
    db_dir "$db_dir" web_dir "$web_dir" geoip_dir "$geoip_dir"
}

# Tracked image lines (after the migration) and remaining .env values.
fill_defaults_from_example() {
  local key
  for key in REDIS_IMAGE MSMTPD_IMAGE GEOIP_UPDATER_IMAGE MATOMO_IMAGE; do
    FINAL_IMAGES[$key]=$(env_file_value "$ENV_EXAMPLE" "$key") || fail config_invalid "$key missing in .env.example"
  done
  [[ -z $MATOMO_IMAGE_OVERRIDE ]] || FINAL_IMAGES[MATOMO_IMAGE]=$MATOMO_IMAGE_OVERRIDE
  # The database stays on the release line it runs now.
  FINAL_IMAGES[MARIADB_IMAGE]="mariadb:$(cut -d. -f1-2 <<<"$OLD_DB_VERSION")"

  ENV_VALUES[MATOMO_START_PERIOD]=${START_PERIOD_OVERRIDE:-$(env_file_value "$ENV_EXAMPLE" MATOMO_START_PERIOD)}
  ENV_VALUES[COMPOSE_PROJECT_NAME]=$OLD_PROJECT

  WAIT_TIMEOUT_SECONDS=${WAIT_TIMEOUT_OVERRIDE:-$(env_file_value "$UPDATE_ENV_EXAMPLE" WAIT_TIMEOUT_SECONDS)}
  HEALTH_RETRIES=$(env_file_value "$UPDATE_ENV_EXAMPLE" HEALTH_RETRIES)
  HEALTH_TIMEOUT_SECONDS=$(env_file_value "$UPDATE_ENV_EXAMPLE" HEALTH_TIMEOUT_SECONDS)
  # Same path as the update script checks, on the published port.
  local health_path
  health_path=$(env_file_value "$UPDATE_ENV_EXAMPLE" HEALTH_URL | sed -E 's|^[a-z]+://[^/]+||')
  HEALTH_URL="http://127.0.0.1:${ENV_VALUES[MATOMO_PUBLISHED_PORT]}${health_path}"

  local start_seconds
  start_seconds=$(duration_to_seconds "${ENV_VALUES[MATOMO_START_PERIOD]}") ||
    fail config_invalid "MATOMO_START_PERIOD is not a duration like 1800s" value "${ENV_VALUES[MATOMO_START_PERIOD]}"
  ((WAIT_TIMEOUT_SECONDS > start_seconds)) ||
    fail config_invalid "the wait timeout must be longer than the Matomo start period" \
      wait_timeout "$WAIT_TIMEOUT_SECONDS" start_period "${ENV_VALUES[MATOMO_START_PERIOD]}"
}

# Chooses the Matomo image for the switch: this repository's image of the
# running Matomo version when published, otherwise the tracked image.
select_matomo_image() {
  local tracked=${FINAL_IMAGES[MATOMO_IMAGE]} same_version label
  same_version="$(image_repository "$tracked"):$OLD_MATOMO_VERSION"
  if docker pull -q "$same_version" >/dev/null 2>&1; then
    label=$(docker image inspect --format "{{ index .Config.Labels \"$VERSION_LABEL\" }}" "$same_version")
    if [[ $label == "$OLD_MATOMO_VERSION" ]]; then
      ENV_VALUES[MATOMO_IMAGE]=$same_version
      NEW_MATOMO_VERSION=$OLD_MATOMO_VERSION
      SAME_MATOMO_VERSION=true
      log info matomo_image_selected "switching to the same Matomo version, no database migration" image "$same_version"
      return 0
    fi
  fi
  docker pull -q "$tracked" >/dev/null || fail pull_failed "cannot pull the Matomo image" image "$tracked"
  label=$(docker image inspect --format "{{ index .Config.Labels \"$VERSION_LABEL\" }}" "$tracked")
  is_stable_version "$label" || fail image_invalid "Matomo image has no version label" image "$tracked"
  [[ ${label%%.*} == "${OLD_MATOMO_VERSION%%.*}" ]] ||
    fail version_mismatch "Matomo major versions differ; upgrade the major version separately" old "$OLD_MATOMO_VERSION" new "$label"
  if version_gt "$OLD_MATOMO_VERSION" "$label"; then
    fail version_mismatch "the Matomo image is older than the running Matomo" old "$OLD_MATOMO_VERSION" new "$label"
  fi
  ENV_VALUES[MATOMO_IMAGE]=$tracked
  NEW_MATOMO_VERSION=$label
  log warn matomo_image_selected "no image of the running Matomo version, the switch also upgrades Matomo (database migrations)" \
    image "$tracked" from "$OLD_MATOMO_VERSION" to "$label"
}

# Writes compose.yml, .env and the env files into DIR.
generate_config() {
  local dir=$1 key
  if [[ $dir == "$NEW_DIR" && ! -e $dir ]]; then
    NEW_DIR_CREATED=true
  fi
  mkdir -p "$dir"
  chmod 700 "$dir"
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
  compose_in "$dir" config --quiet || fail config_invalid "generated configuration is invalid" dir "$dir"
}

# Checks the resolved compose model against the values the plan shows.
validate_generated() {
  local dir=$1 config problems
  config=$(compose_in "$dir" config --format json) || fail config_invalid "cannot resolve generated configuration"
  problems=$(jq -r \
    --arg project "$OLD_PROJECT" --arg db "${ENV_VALUES[MATOMO_DB_DIR]}" \
    --arg web "${ENV_VALUES[MATOMO_WEB_DIR]}" --arg geoip "${ENV_VALUES[MATOMO_GEOIP_DIR]}" \
    --arg db_image "${ENV_VALUES[MARIADB_IMAGE]}" --arg matomo_image "${ENV_VALUES[MATOMO_IMAGE]}" \
    --argjson old_db_cmd "$(docker inspect --format '{{json .Config.Cmd}}' "${OLD_CID[db]}")" '
    def src($s; $t): [.services[$s].volumes[] | select(.target == $t) | .source][0];
    [ (if .name != $project then "project name \(.name)" else empty end),
      (if src("db"; "/var/lib/mysql") != $db then "db data dir" else empty end),
      (if src("matomo"; "/data") != $web then "matomo data dir" else empty end),
      (if src("matomo"; "/data/geoip") != $geoip then "geoip dir" else empty end),
      (if .services.db.image != $db_image then "db image" else empty end),
      (if .services.matomo.image != $matomo_image then "matomo image" else empty end),
      (if .services.db.command != $old_db_cmd then "db command differs from the old one: \(.services.db.command)" else empty end)
    ] | .[]' <<<"$config")
  [[ -z $problems ]] || fail config_invalid "generated configuration does not match the plan" problems "$(tr '\n' ';' <<<"$problems")"
}

print_plan() {
  local entries svc
  entries=$(movable_entries | sed "s|^$OLD_DIR/||" | tr '\n' ' ')
  cat <<EOF

Migration plan
  old stack:      $OLD_DIR/$OLD_COMPOSE (project $OLD_PROJECT)
  new stack:      $NEW_DIR/compose.yml (same project name, containers are recreated)
  Matomo:         $OLD_MATOMO_VERSION -> $NEW_MATOMO_VERSION (${ENV_VALUES[MATOMO_IMAGE]})
EOF
  if ! $SAME_MATOMO_VERSION; then
    echo "                  WARNING: Matomo is upgraded during the switch (database migrations)."
  fi
  for svc in db redis msmtpd geoip-updater; do
    printf '  %-15s kept as is (%s)\n' "$svc:" "${ENV_VALUES[${PINNED_IMAGE_KEYS[$svc]}]}"
  done
  cat <<EOF
  data (stays):   ${ENV_VALUES[MATOMO_DB_DIR]}
                  ${ENV_VALUES[MATOMO_WEB_DIR]}
                  ${ENV_VALUES[MATOMO_GEOIP_DIR]}
  backup to:      $BACKUP_DIR
  moved to $OLD_SUBDIR: $entries
  downtime:       from replacing the old containers until the new stack is verified
  afterwards:     .env tracks MATOMO_IMAGE=${FINAL_IMAGES[MATOMO_IMAGE]}, MARIADB_IMAGE=${FINAL_IMAGES[MARIADB_IMAGE]},
                  REDIS_IMAGE=${FINAL_IMAGES[REDIS_IMAGE]}, MSMTPD_IMAGE=${FINAL_IMAGES[MSMTPD_IMAGE]},
                  GEOIP_UPDATER_IMAGE=${FINAL_IMAGES[GEOIP_UPDATER_IMAGE]};
                  the next matomo-update.sh run upgrades to them (with backup and rollback)
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
  { : </dev/tty; } 2>/dev/null || fail confirmation_required "no terminal to confirm on; use --yes"
  local answer
  read -r -p "Proceed with the switch (short downtime)? [y/N] " answer </dev/tty
  [[ $answer == y || $answer == Y || $answer == yes ]] || fail aborted "migration aborted by the user, nothing was changed"
}

# Fails when the backup filesystem has less free space than the database
# holds (an uncompressed logical dump is about that size; gzip only makes it
# smaller, so this bound keeps the live database from running out of disk).
check_backup_space() {
  local need free
  need=$(db_size_sql | db_query "${OLD_CID[db]}") || return 1
  free=$(df -Pk "$BACKUP_DIR" | awk 'NR == 2 { print $4 * 1024 }')
  if ((free < need)); then
    log error backup_space "not enough free space for the database dump" dir "$BACKUP_DIR" \
      free_bytes "$free" database_bytes "$need"
    return 1
  fi
  if [[ $(df -P "$BACKUP_DIR" | awk 'NR == 2 { print $1 }') == $(df -P "${ENV_VALUES[MATOMO_DB_DIR]}" | awk 'NR == 2 { print $1 }') ]]; then
    log warn backup_same_filesystem "backups are written to the filesystem of the database" dir "$BACKUP_DIR"
  fi
}

create_backup() {
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || return 1
  check_backup_space || return 1
  DB_BACKUP_FILE="$BACKUP_DIR/matomo-db-$RUN_ID-pre-migration.sql.gz"
  local partial="$DB_BACKUP_FILE.partial"
  CONFIG_BACKUP_FILE="$BACKUP_DIR/matomo-config-$RUN_ID-pre-migration.tar.gz"
  # shellcheck disable=SC2016
  if ! docker exec "${OLD_CID[db]}" sh -c '
      dump=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || dump=mysqldump
      MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$dump" \
        --single-transaction --quick --add-drop-database \
        -u"${MARIADB_USER:-$MYSQL_USER}" --databases "${MARIADB_DATABASE:-$MYSQL_DATABASE}"' |
    gzip >"$partial"; then
    return 1
  fi
  gzip -t "$partial" || return 1
  gzip -dc "$partial" | tail -n1 | grep -q '^-- Dump completed' || return 1
  local tables
  tables=$(gzip -dc "$partial" | grep -c '^CREATE TABLE' || true)
  if $MATOMO_INSTALLED && ((tables == 0)); then
    log error backup_empty "Matomo is installed but the dump contains no tables"
    return 1
  fi
  mv "$partial" "$DB_BACKUP_FILE" || return 1
  tar -C "${ENV_VALUES[MATOMO_WEB_DIR]}" -czf "$CONFIG_BACKUP_FILE" config || return 1
  PRE_DB_FINGERPRINT=$(db_fingerprint_sql "$TABLE_PREFIX" "$MATOMO_INSTALLED" | db_query "${OLD_CID[db]}") || return 1
  [[ -n $PRE_DB_FINGERPRINT ]] || return 1
  log info backup_created "backup created" db_backup "$DB_BACKUP_FILE" tables "$tables" \
    config_backup "$CONFIG_BACKUP_FILE" schema_fingerprint "$PRE_DB_FINGERPRINT"
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
  # Something left behind must not stop the rollback of the service.
  rmdir "$OLD_DIR/$OLD_SUBDIR" 2>/dev/null ||
    log warn rollback_step "$OLD_SUBDIR is not empty after moving the files back" dir "$OLD_DIR/$OLD_SUBDIR"
}

# restore_config ARCHIVE - replaces config/ with the archived one; files the
# new version added are removed too. The current tree is kept aside until
# the archive is extracted.
restore_config() {
  local web=${ENV_VALUES[MATOMO_WEB_DIR]} aside
  aside="$web/config.before-rollback-$RUN_ID"
  mv "$web/config" "$aside" || return 1
  if tar -C "$web" -xzf "$1"; then
    rm -rf "$aside"
  else
    rm -rf "$web/config"
    mv "$aside" "$web/config"
    return 1
  fi
}

http_check() {
  curl -fsS -o /dev/null --max-time "$HEALTH_TIMEOUT_SECONDS" \
    --retry "$HEALTH_RETRIES" --retry-all-errors --retry-delay 2 "$HEALTH_URL"
}

verify_new_stack() {
  local actual output
  if ! http_check; then
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

# Removes every container of the project and proves that none is left, so
# that nothing writes to the database while it may be restored.
remove_project_containers() {
  local left
  new_compose down --remove-orphans || log warn rollback_step "compose down reported an error"
  left=$(docker ps -aq --filter "label=com.docker.compose.project=$OLD_PROJECT")
  if [[ -n $left ]]; then
    # shellcheck disable=SC2086
    docker rm -f $left >/dev/null || true
    left=$(docker ps -aq --filter "label=com.docker.compose.project=$OLD_PROJECT")
  fi
  [[ -z $left ]]
}

rollback() {
  PHASE=rolling_back
  log warn rollback_started "rolling back to the old stack"
  if ! remove_project_containers; then
    log error rollback_failed "containers of the project could not be removed, database left untouched"
    exit 2
  fi
  if ! restore_old_files; then
    log error rollback_failed "cannot move files back from $OLD_SUBDIR" dir "$OLD_DIR/$OLD_SUBDIR"
    exit 2
  fi
  local svc
  for svc in "${SERVICES[@]}"; do
    docker tag "${OLD_IMAGE_ID[$svc]}" "${OLD_IMAGE_REF[$svc]}" ||
      log warn rollback_step "cannot re-tag the old image" service "$svc" image "${OLD_IMAGE_REF[$svc]}"
  done
  if ! old_compose up --pull never -d db || ! wait_for_old_db; then
    log error rollback_failed "old database does not start" db_backup "$DB_BACKUP_FILE"
    exit 2
  fi
  local post
  post=$(db_fingerprint_sql "$TABLE_PREFIX" "$MATOMO_INSTALLED" | db_query "$(old_db_cid)") || post=""
  if [[ -n $post && $post == "$PRE_DB_FINGERPRINT" ]]; then
    log info db_unchanged "database schema unchanged, keeping all data (no restore)"
  else
    log warn db_restore "database schema changed, restoring the pre-migration dump; data tracked since the backup is discarded" \
      before "$PRE_DB_FINGERPRINT" after "$post"
    if ! gzip -dc "$DB_BACKUP_FILE" | old_compose exec -T db sh -c "$DB_CLIENT_SNIPPET"; then
      log error rollback_failed "database restore failed" db_backup "$DB_BACKUP_FILE"
      exit 2
    fi
  fi
  if ! restore_config "$CONFIG_BACKUP_FILE"; then
    log error rollback_failed "config restore failed" config_backup "$CONFIG_BACKUP_FILE"
    exit 2
  fi
  if ! old_compose up --pull never -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" || ! http_check; then
    log error rollback_failed "old stack does not become healthy" compose_file "$OLD_DIR/$OLD_COMPOSE"
    exit 2
  fi
  log warn rollback_succeeded "old stack is running again" \
    new_dir "$NEW_DIR" downtime_seconds "$((SECONDS - SWITCH_STARTED_AT))"
  exit 1
}

# EXIT trap: an interruption (signal or unexpected error) must not leave the
# stack half switched.
on_exit() {
  local status=$?
  # Nothing was switched: leave no half-prepared NEW_DIR behind, so that the
  # migration can simply be started again.
  if [[ $PHASE == idle && $status -ne 0 ]] && $NEW_DIR_CREATED; then
    rm -rf "$NEW_DIR"
  fi
  case $PHASE in
    backup)
      old_compose start cron >/dev/null 2>&1 || true
      log error interrupted "interrupted before the switch, old cron restarted" status "$status"
      ;;
    switching)
      log error interrupted "interrupted during the switch, rolling back" status "$status"
      rollback
      ;;
  esac
  [[ -z $DRY_RUN_DIR ]] || rm -rf "$DRY_RUN_DIR"
}

switch() {
  PHASE=backup
  old_compose stop cron || fail switch_failed "cannot stop the old cron sidecar"
  if ! create_backup; then
    old_compose start cron || true
    PHASE=idle
    fail backup_failed "backup failed, nothing was changed (cron restarted)" db_backup "$DB_BACKUP_FILE"
  fi

  PHASE=switching
  SWITCH_STARTED_AT=$SECONDS
  log info downtime_started "replacing the old containers"
  if ! move_old_files; then
    log error switch_failed "cannot move old files"
    rollback
  fi
  local svcs=()
  mapfile -t svcs < <(printf '%s\n' "${SERVICES[@]}" | grep -vx cron)
  if ! new_compose up --pull never -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" "${svcs[@]}"; then
    log error switch_failed "new stack did not become healthy"
    rollback
  fi
  verify_new_stack || rollback
  if ! new_compose up --pull never -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" cron; then
    log error switch_failed "new cron sidecar did not start"
    rollback
  fi
  PHASE=switched
  log info downtime_ended "new stack is serving" downtime_seconds "$((SECONDS - SWITCH_STARTED_AT))"
}

# Points .env at the tracked image lines; the running containers are not
# touched, matomo-update.sh deploys the new images.
finalize_env() {
  local key
  for key in "${!FINAL_IMAGES[@]}"; do
    set_env_file_value "$NEW_DIR/.env" "$key" "${FINAL_IMAGES[$key]}" ||
      fail finalize_failed "cannot update .env" key "$key"
  done
  compose_in "$NEW_DIR" config --quiet || fail finalize_failed "final .env is invalid"
  log info env_finalized "new .env tracks the supported image lines" \
    matomo_image "${FINAL_IMAGES[MATOMO_IMAGE]}" mariadb_image "${FINAL_IMAGES[MARIADB_IMAGE]}"
}

install_timer() {
  if ! "$INSTALL_TIMER" "$NEW_DIR" "$BACKUP_DIR" "$HEALTH_URL" "$WAIT_TIMEOUT_SECONDS"; then
    log error timer_failed "migration succeeded, but the systemd timer could not be installed" \
      command "$INSTALL_TIMER $NEW_DIR $BACKUP_DIR $HEALTH_URL $WAIT_TIMEOUT_SECONDS"
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
                    (config /etc/matomo-update/matomo-update.env, log in journalctl -u matomo-update);
                    its next run upgrades to the image lines in $NEW_DIR/.env
  migration log:    $LOG_FILE

Recommended follow-up (see MIGRATION.md): set a MariaDB root password,
move to a newer MariaDB LTS in a separate maintenance window.
EOF
}

main() {
  parse_args "$@"
  trap on_exit EXIT
  trap 'exit 130' INT TERM HUP
  check_environment
  check_dirs
  log info migration_started "inspecting the old stack" old_dir "$OLD_DIR" new_dir "$NEW_DIR" dry_run "$DRY_RUN"
  inspect_old_stack
  fill_defaults_from_example
  select_matomo_image

  if $DRY_RUN; then
    DRY_RUN_DIR=$(mktemp -d)
    generate_config "$DRY_RUN_DIR"
    validate_generated "$DRY_RUN_DIR"
    print_plan
    print_generated_env "$DRY_RUN_DIR"
    log info dry_run_finished "dry run finished: the running stack and OLD_DIR are unchanged"
    exit 0
  fi

  generate_config "$NEW_DIR"
  validate_generated "$NEW_DIR"
  LOG_FILE="$NEW_DIR/migration.log"
  print_plan
  print_generated_env "$NEW_DIR"
  confirm
  switch
  finalize_env
  install_timer
  log info migration_succeeded "migration finished"
  print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
