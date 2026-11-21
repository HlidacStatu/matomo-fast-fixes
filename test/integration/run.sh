#!/usr/bin/env bash
# Integration test of server/matomo-update.sh against a real Docker stack.
#
# A local registry plays GHCR. Three variants of the candidate image are pushed
# to the tracked tag one after another:
#   v1     - initial deployment
#   v2     - a regular update: must be deployed, backup must be created
#   broken - healthcheck always fails and, on its first probe, drops a marker
#            table (simulating a destructive migration): the script must roll
#            back to v2, restore the database (marker table back) and block
#            the broken image so the next run skips it.
#
# Usage: test/integration/run.sh CANDIDATE_IMAGE
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 CANDIDATE_IMAGE" >&2; exit 1; }
CANDIDATE=$1

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=test/integration/it.env
source "$TEST_DIR/it.env"

WORK="$TEST_DIR/work"
UPDATE="$REPO_DIR/server/matomo-update.sh"
IMAGE="$IT_REGISTRY/matomo"
TRACKED="$IMAGE:$IT_TRACKED_TAG"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  if ((status != 0)) && [[ -d $WORK ]]; then
    echo "--- update log"
    cat "$WORK/log/update.log" 2>/dev/null || true
    echo "--- compose logs"
    (cd "$WORK" && docker compose logs --no-color --tail 200) || true
  fi
  if [[ -d $WORK ]]; then
    (cd "$WORK" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
  fi
  docker rm -f "$IT_REGISTRY_CONTAINER" >/dev/null 2>&1 || true
  sudo -n rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

compose() {
  (cd "$WORK" && docker compose "$@")
}

# Prints the image ID the container of SERVICE runs.
running_image() {
  docker inspect --format '{{.Image}}' "$(compose ps -a -q "$1")"
}

image_id() {
  docker image inspect --format '{{.Id}}' "$1"
}

publish() {
  docker tag "$1" "$TRACKED"
  docker push -q "$TRACKED" >/dev/null
}

last_event() {
  tail -n1 "$WORK/log/update.log" | jq -r .event
}

# has_event EVENT [FROM_LINE] - succeeds when EVENT was logged (optionally after FROM_LINE).
has_event() {
  tail -n +"$((${2:-0} + 1))" "$WORK/log/update.log" | jq -e --arg e "$1" 'select(.event == $e)' >/dev/null
}

log_lines() {
  wc -l <"$WORK/log/update.log" | tr -d ' '
}

marker_value() {
  # shellcheck disable=SC2016
  compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "SELECT v FROM it_marker"' 2>/dev/null || true
}

run_update() {
  local status=0
  "$UPDATE" "$WORK/matomo-update.env" >/dev/null || status=$?
  echo "$status"
}

echo "--- preparing images"
docker run -d --name "$IT_REGISTRY_CONTAINER" -p "$IT_REGISTRY_BIND:5000" "$IT_REGISTRY_IMAGE" >/dev/null

printf 'FROM %s\nLABEL it.variant=v1\n' "$CANDIDATE" | docker build -q -t "$IMAGE:v1" - >/dev/null
printf 'FROM %s\nLABEL it.variant=v2\n' "$CANDIDATE" | docker build -q -t "$IMAGE:v2" - >/dev/null
docker build -q -t "$IMAGE:broken" --build-arg "BASE=$CANDIDATE" -f "$TEST_DIR/broken.Dockerfile" "$TEST_DIR" >/dev/null

echo "--- preparing stack"
rm -rf "$WORK"
mkdir -p "$WORK/data" "$WORK/log"
cp "$REPO_DIR/server/compose.yml" "$WORK/compose.yml"
cp "$TEST_DIR/compose.override.yml" "$WORK/compose.override.yml"
cp "$REPO_DIR/server/matomo.env.example" "$WORK/matomo.env"
printf 'IT_DB_PASSWORD=%s\n' "$IT_DB_PASSWORD" >>"$WORK/matomo.env"
touch "$WORK/msmtpd.env" "$WORK/geoip-updater.env"
sed -e "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=$IT_PROJECT_NAME|" \
  -e "s|^MATOMO_DATA_DIR=.*|MATOMO_DATA_DIR=$WORK/data|" \
  -e "s|^MATOMO_IMAGE=.*|MATOMO_IMAGE=$TRACKED|" \
  -e "s|^MATOMO_START_PERIOD=.*|MATOMO_START_PERIOD=$IT_START_PERIOD|" \
  -e "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$IT_DB_PASSWORD|" \
  "$REPO_DIR/server/.env.example" >"$WORK/.env"
sed -e "s|^COMPOSE_DIR=.*|COMPOSE_DIR=$WORK|" \
  -e "s|^BACKUP_DIR=.*|BACKUP_DIR=$WORK/backups|" \
  -e "s|^STATE_DIR=.*|STATE_DIR=$WORK/state|" \
  -e "s|^LOG_FILE=.*|LOG_FILE=$WORK/log/update.log|" \
  -e "s|^LOCK_FILE=.*|LOCK_FILE=$WORK/update.lock|" \
  -e "s|^WAIT_TIMEOUT_SECONDS=.*|WAIT_TIMEOUT_SECONDS=$IT_WAIT_TIMEOUT_SECONDS|" \
  "$REPO_DIR/server/matomo-update.env.example" >"$WORK/matomo-update.env"

publish "$IMAGE:v1"
compose up -d --wait --wait-timeout "$IT_WAIT_TIMEOUT_SECONDS"
# shellcheck disable=SC2016
compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "CREATE TABLE it_marker (v INT); INSERT INTO it_marker VALUES (42);"'

echo "--- case 1: nothing new"
status=$(run_update)
[[ $status == 0 ]] || fail "expected exit 0, got $status"
[[ $(last_event) == no_update ]] || fail "expected no_update, got $(last_event)"

echo "--- case 2: regular update"
publish "$IMAGE:v2"
v2_id=$(image_id "$IMAGE:v2")
status=$(run_update)
[[ $status == 0 ]] || fail "expected exit 0, got $status"
[[ $(last_event) == update_succeeded ]] || fail "expected update_succeeded, got $(last_event)"
[[ $(running_image matomo) == "$v2_id" ]] || fail "matomo does not run v2"
[[ $(running_image cron) == "$v2_id" ]] || fail "cron does not run v2"
ls "$WORK"/backups/matomo-db-*.sql.gz >/dev/null || fail "no database backup"
ls "$WORK"/backups/matomo-config-*.tar.gz >/dev/null || fail "no config backup"
[[ $(marker_value) == 42 ]] || fail "marker table lost after update"

echo "--- case 3: broken update is rolled back"
publish "$IMAGE:broken"
broken_id=$(image_id "$IMAGE:broken")
mark=$(log_lines)
status=$(run_update)
[[ $status == 1 ]] || fail "expected exit 1, got $status"
has_event restore_succeeded "$mark" || fail "database was not restored"
[[ $(last_event) == rollback_succeeded ]] || fail "expected rollback_succeeded, got $(last_event)"
[[ $(running_image matomo) == "$v2_id" ]] || fail "matomo was not rolled back to v2"
[[ $(running_image cron) == "$v2_id" ]] || fail "cron was not rolled back to v2"
[[ $(marker_value) == 42 ]] || fail "marker table not restored"
grep -qF "$broken_id" "$WORK/state/blocked-images" || fail "broken image not blocked"

echo "--- case 4: blocked image is skipped"
mark=$(log_lines)
status=$(run_update)
[[ $status == 0 ]] || fail "expected exit 0, got $status"
has_event image_blocked "$mark" || fail "blocked image was not reported"
[[ $(last_event) == no_update ]] || fail "expected no_update, got $(last_event)"
[[ $(running_image matomo) == "$v2_id" ]] || fail "matomo does not run v2 anymore"

echo "integration test passed"
