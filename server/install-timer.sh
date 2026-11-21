#!/usr/bin/env bash
# Installs and enables the systemd timer that runs matomo-update.sh.
#
#   - creates /etc/matomo-update/matomo-update.env from the example with the
#     given values (an existing file is kept untouched),
#   - renders server/systemd/matomo-update.{service,timer} with the real path
#     of this checkout into /etc/systemd/system,
#   - enables and starts the timer and prints when it runs next.
#
# Usage: install-timer.sh COMPOSE_DIR BACKUP_DIR HEALTH_URL   (as root)
set -euo pipefail

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

[[ $# -eq 3 ]] || die "usage: $0 COMPOSE_DIR BACKUP_DIR HEALTH_URL"
COMPOSE_DIR=$1
BACKUP_DIR=$2
HEALTH_URL=$3

[[ $EUID -eq 0 ]] || die "must run as root"
command -v systemctl >/dev/null || die "systemctl not found"
[[ -f $COMPOSE_DIR/compose.yml ]] || die "no compose.yml in $COMPOSE_DIR"

install -d -m 700 "$CONFIG_DIR"
if [[ -f $CONFIG_FILE ]]; then
  echo "Keeping existing $CONFIG_FILE (not overwritten)"
else
  sed -e "s|^COMPOSE_DIR=.*|COMPOSE_DIR=$COMPOSE_DIR|" \
    -e "s|^BACKUP_DIR=.*|BACKUP_DIR=$BACKUP_DIR|" \
    -e "s|^HEALTH_URL=.*|HEALTH_URL=$HEALTH_URL|" \
    "$SCRIPT_DIR/matomo-update.env.example" >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "Created $CONFIG_FILE"
fi

sed -e "s|@UPDATE_SCRIPT@|$SCRIPT_DIR/matomo-update.sh|" \
  -e "s|@UPDATE_CONFIG@|$CONFIG_FILE|" \
  "$SCRIPT_DIR/systemd/$SERVICE_UNIT" >"$UNIT_DIR/$SERVICE_UNIT"
install -m 644 "$SCRIPT_DIR/systemd/$TIMER_UNIT" "$UNIT_DIR/$TIMER_UNIT"

systemctl daemon-reload
systemctl enable --now "$TIMER_UNIT"

echo
echo "Automatic updates are enabled:"
echo "  timer:   $UNIT_DIR/$TIMER_UNIT"
echo "  service: $UNIT_DIR/$SERVICE_UNIT -> $SCRIPT_DIR/matomo-update.sh"
echo "  config:  $CONFIG_FILE"
systemctl list-timers "$TIMER_UNIT" --no-pager
