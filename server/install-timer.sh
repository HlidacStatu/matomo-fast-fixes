#!/usr/bin/env bash
# Installs and enables the systemd timer that runs matomo-update.sh.
#
#   - writes /etc/matomo-update/matomo-update.env from the example with the
#     given values. An existing file is updated only when it points to the
#     same COMPOSE_DIR (otherwise the script stops instead of silently leaving
#     the timer bound to another stack): the four given values are replaced,
#     its other values are kept, keys new in the example are added and
#     settings that are not in the example (e.g. DOCKER_HOST) are carried
#     over verbatim,
#   - renders server/systemd/matomo-update.{service,timer} with the real path
#     of this checkout into /etc/systemd/system,
#   - enables and starts the timer and prints when it runs next.
#
# Usage: install-timer.sh COMPOSE_DIR BACKUP_DIR HEALTH_URL WAIT_TIMEOUT_SECONDS   (as root)
set -euo pipefail
umask 077

# Standard locations (filesystem hierarchy / systemd conventions).
CONFIG_DIR=/etc/matomo-update
CONFIG_FILE=$CONFIG_DIR/matomo-update.env
UNIT_DIR=/etc/systemd/system
TIMER_UNIT=matomo-update.timer
SERVICE_UNIT=matomo-update.service

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# config_value FILE KEY - KEY's value in an existing config (sourced in a
# subshell); fails when the file does not set it.
config_value() {
  (
    # Only what the file sets counts, not the installer's environment.
    unset -v "$2"
    set +u
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    [[ -n ${!2+set} ]] || exit 1
    printf '%s' "${!2}"
  )
}

# render_config EXAMPLE EXISTING COMPOSE_DIR BACKUP_DIR HEALTH_URL WAIT_TIMEOUT_SECONDS
# Prints the example with the given keys replaced and, when EXISTING is a
# file, every other key set to its value there. The file is sourced by bash,
# so the values are quoted with printf %q.
render_config() {
  local example=$1 existing=$2 line key value
  local -A values=([COMPOSE_DIR]=$3 [BACKUP_DIR]=$4 [HEALTH_URL]=$5 [WAIT_TIMEOUT_SECONDS]=$6)
  while IFS= read -r line || [[ -n $line ]]; do
    key=${line%%=*}
    if [[ $line == *=* && -n ${values[$key]+set} ]]; then
      printf '%s=%q\n' "$key" "${values[$key]}"
    elif [[ $line == *=* && -f $existing ]] && value=$(config_value "$existing" "$key"); then
      printf '%s=%q\n' "$key" "$value"
    else
      printf '%s\n' "$line"
    fi
  done <"$example"
  [[ -f $existing ]] || return 0
  local extra
  extra=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$existing" | while IFS= read -r line; do
    grep -qE "^${line%%=*}=" "$example" || printf '%s\n' "$line"
  done)
  if [[ -n $extra ]]; then
    printf '\n# Kept from the previous configuration (not in the example).\n%s\n' "$extra"
  fi
}

# systemd_quote VALUE - a double-quoted systemd command line argument.
systemd_quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//%/%%}
  printf '"%s"' "$v"
}

# render_service TEMPLATE SCRIPT CONFIG - fills the ExecStart placeholders.
render_service() {
  local template=$1 script config line
  script=$(systemd_quote "$2")
  config=$(systemd_quote "$3")
  # Bash 5.2 treats & in a pattern replacement as the match; keep it literal.
  shopt -u patsub_replacement 2>/dev/null || true
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line//@UPDATE_SCRIPT@/$script}
    line=${line//@UPDATE_CONFIG@/$config}
    printf '%s\n' "$line"
  done <"$template"
}

# Prints COMPOSE_DIR of an existing config file (sourced in a subshell).
configured_compose_dir() {
  (
    unset -v COMPOSE_DIR
    set +u
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    printf '%s' "${COMPOSE_DIR:-}"
  )
}

main() {
  [[ $# -eq 4 ]] || die "usage: $0 COMPOSE_DIR BACKUP_DIR HEALTH_URL WAIT_TIMEOUT_SECONDS"
  local compose_dir=$1 backup_dir=$2 health_url=$3 wait_timeout=$4
  [[ $wait_timeout =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT_SECONDS must be a number: $wait_timeout"
  [[ $EUID -eq 0 ]] || die "must run as root"
  command -v systemctl >/dev/null || die "systemctl not found"
  [[ -f $compose_dir/compose.yml ]] || die "no compose.yml in $compose_dir"

  install -d -m 700 "$CONFIG_DIR"
  local existing="" action=Created tmp
  if [[ -f $CONFIG_FILE ]]; then
    existing=$(configured_compose_dir "$CONFIG_FILE")
    [[ $existing == "$compose_dir" ]] ||
      die "$CONFIG_FILE already points to COMPOSE_DIR=$existing, not $compose_dir; fix or remove it first"
    existing=$CONFIG_FILE
    action=Updated
  fi
  tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
  render_config "$SCRIPT_DIR/matomo-update.env.example" "$existing" \
    "$compose_dir" "$backup_dir" "$health_url" "$wait_timeout" >"$tmp"
  chmod 600 "$tmp"
  [[ $(configured_compose_dir "$tmp") == "$compose_dir" ]] || { rm -f "$tmp"; die "rendered config does not parse back"; }
  mv "$tmp" "$CONFIG_FILE"
  echo "$action $CONFIG_FILE"


  (
    umask 022
    render_service "$SCRIPT_DIR/systemd/$SERVICE_UNIT" "$SCRIPT_DIR/matomo-update.sh" "$CONFIG_FILE" >"$UNIT_DIR/$SERVICE_UNIT"
    install -m 644 "$SCRIPT_DIR/systemd/$TIMER_UNIT" "$UNIT_DIR/$TIMER_UNIT"
  )
  if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$TIMER_UNIT" || die "systemd rejected the rendered units"
  fi

  systemctl daemon-reload
  systemctl enable --now "$TIMER_UNIT"

  echo
  echo "Automatic updates are enabled:"
  echo "  timer:   $UNIT_DIR/$TIMER_UNIT"
  echo "  service: $UNIT_DIR/$SERVICE_UNIT -> $SCRIPT_DIR/matomo-update.sh"
  echo "  config:  $CONFIG_FILE"
  systemctl list-timers "$TIMER_UNIT" --no-pager
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
