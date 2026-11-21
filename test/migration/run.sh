#!/usr/bin/env bash
# Integration test of server/migrate-from-crazymax.sh (must run as root: the
# migration installs the systemd timer).
#
# Starts the old crazymax stack (test/migration/docker-compose.crazymax.yml),
# creates a marker table and then:
#   1. --dry-run              must change nothing,
#   2. migration to a broken image (healthcheck fails and drops the marker
#      table) must roll back: old files back, old images running, marker
#      table restored from the backup, no timer installed,
#   3. migration to the candidate image must succeed: old files in _old_,
#      data untouched, environment carried over, timer installed and a
#      first matomo-update run reports nothing to do.
#
# Usage: test/migration/run.sh CANDIDATE_IMAGE
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 CANDIDATE_IMAGE" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
CANDIDATE=$1

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=test/migration/it.env
source "$TEST_DIR/it.env"

WORK="$TEST_DIR/work"
OLD="$WORK/old"
DATA="$WORK/data"
MIGRATE="$REPO_DIR/server/migrate-from-crazymax.sh"
IMAGE="$IT_REGISTRY/matomo"
UPDATE_CONFIG=/etc/matomo-update/matomo-update.env
UPDATE_LOG=/var/log/matomo-update/matomo-update.log

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  if ((status != 0)); then
    for dir in "$OLD" "$WORK"/new*; do
      [[ -d $dir ]] || continue
      echo "--- logs of $dir"
      cat "$dir/migration.log" 2>/dev/null || true
      (cd "$dir" && docker compose logs --no-color --tail 100) 2>/dev/null || true
    done
    journalctl -u matomo-update --no-pager -n 50 2>/dev/null || true
  fi
  systemctl disable --now matomo-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/matomo-update.service /etc/systemd/system/matomo-update.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf /etc/matomo-update /var/log/matomo-update /var/lib/matomo-update
  for dir in "$WORK"/new* "$OLD"; do
    [[ -f $dir/compose.yml || -f $dir/docker-compose.yml ]] || continue
    (cd "$dir" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
  done
  docker rm -f "$IT_REGISTRY_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

old_compose() {
  (cd "$OLD" && docker compose "$@")
}

running_image() {
  local dir=$1 svc=$2
  docker inspect --format '{{.Image}}' "$(cd "$dir" && docker compose ps -q "$svc")"
}

image_id() {
  docker image inspect --format '{{.Id}}' "$1"
}

marker_value() {
  local dir=$1
  # shellcheck disable=SC2016
  (cd "$dir" && docker compose exec -T db sh -c \
    'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "SELECT v FROM it_marker"') 2>/dev/null || true
}

container_env_value() {
  local dir=$1 svc=$2 key=$3
  (cd "$dir" && docker compose exec -T "$svc" printenv "$key")
}

migrate() {
  local status=0
  "$MIGRATE" --yes --start-period "$IT_START_PERIOD" --wait-timeout "$IT_WAIT_TIMEOUT_SECONDS" "$@" || status=$?
  echo "$status"
}

echo "--- preparing images"
docker run -d --name "$IT_REGISTRY_CONTAINER" -p "$IT_REGISTRY_BIND:5000" "$IT_REGISTRY_IMAGE" >/dev/null
docker tag "$CANDIDATE" "$IMAGE:5"
docker push -q "$IMAGE:5" >/dev/null
docker build -q -t "$IMAGE:broken" --build-arg "BASE=$CANDIDATE" \
  -f "$REPO_DIR/test/integration/broken.Dockerfile" "$REPO_DIR/test/integration" >/dev/null
docker push -q "$IMAGE:broken" >/dev/null

echo "--- starting the old crazymax stack"
rm -rf "$WORK"
mkdir -p "$OLD" "$DATA"
sed "s|/data/matomo|$DATA|g" "$TEST_DIR/docker-compose.crazymax.yml" >"$OLD/docker-compose.yml"
cp "$TEST_DIR/matomo.env" "$TEST_DIR/msmtpd.env" "$TEST_DIR/geoip-updater.env" "$OLD/"
echo "notes kept next to the old compose file" >"$OLD/notes.txt"
old_compose up -d --wait --wait-timeout "$IT_WAIT_TIMEOUT_SECONDS"
old_image=$(running_image "$OLD" matomo)
deadline=$((SECONDS + IT_WAIT_TIMEOUT_SECONDS))
# shellcheck disable=SC2016
until old_compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "CREATE TABLE it_marker (v INT); INSERT INTO it_marker VALUES (42);"' 2>/dev/null; do
  ((SECONDS < deadline)) || fail "old database does not accept connections"
  sleep 2
done

echo "--- case 1: dry run changes nothing"
status=0
"$MIGRATE" --dry-run --matomo-image "$IMAGE:5" "$OLD" "$WORK/new-dry" || status=$?
[[ $status == 0 ]] || fail "dry run exited with $status"
[[ ! -e $WORK/new-dry ]] || fail "dry run created NEW_DIR"
[[ -f $OLD/docker-compose.yml && ! -e $OLD/_old_ ]] || fail "dry run touched OLD_DIR"
[[ $(running_image "$OLD" matomo) == "$old_image" ]] || fail "dry run changed the running stack"

echo "--- case 2: failed migration is rolled back"
status=$(migrate --matomo-image "$IMAGE:broken" "$OLD" "$WORK/new-broken")
[[ $status == 1 ]] || fail "expected exit 1, got $status"
grep -q '"event":"rollback_succeeded"' "$WORK/new-broken/migration.log" || fail "no rollback_succeeded event"
[[ -f $OLD/docker-compose.yml && -f $OLD/notes.txt && ! -e $OLD/_old_ ]] || fail "old files were not moved back"
[[ $(running_image "$OLD" matomo) == "$old_image" ]] || fail "old matomo image is not running"
[[ $(marker_value "$OLD") == 42 ]] || fail "marker table was not restored"
[[ ! -f /etc/systemd/system/matomo-update.timer ]] || fail "timer installed after a failed migration"

echo "--- case 3: successful migration"
NEW="$WORK/new"
status=$(migrate --matomo-image "$IMAGE:5" "$OLD" "$NEW")
[[ $status == 0 ]] || fail "expected exit 0, got $status"
for file in docker-compose.yml matomo.env msmtpd.env geoip-updater.env notes.txt; do
  [[ -e $OLD/_old_/$file ]] || fail "$file was not moved to _old_"
  [[ ! -e $OLD/$file ]] || fail "$file is still in OLD_DIR"
done
[[ -d $DATA/db/mysql && -d $DATA/web/config ]] || fail "data directories are missing"
[[ $(running_image "$NEW" matomo) == "$(image_id "$IMAGE:5")" ]] || fail "new matomo image is not running"
[[ $(running_image "$NEW" cron) == "$(image_id "$IMAGE:5")" ]] || fail "new cron image is not running"
[[ $(marker_value "$NEW") == 42 ]] || fail "marker table lost"
grep -Eq "^MARIADB_IMAGE='mariadb:[0-9]+\.[0-9]+'$" "$NEW/.env" || fail "MariaDB line not pinned"
# shellcheck disable=SC2016
[[ $(container_env_value "$NEW" msmtpd SMTP_PASSWORD) == 'bar$baz' ]] || fail "msmtpd password not carried over literally"
[[ $(container_env_value "$NEW" matomo MEMORY_LIMIT) == 256M ]] || fail "matomo.env not carried over"
[[ $(container_env_value "$NEW" cron CRON_ARCHIVE) == '0 * * * *' ]] || fail "cron schedule not carried over"
[[ $(docker ps -q --filter "label=com.docker.compose.project=old" --filter "label=com.docker.compose.project.working_dir=$OLD" | wc -l) == 0 ]] ||
  fail "containers of the old compose file are still running"

systemctl is-enabled --quiet matomo-update.timer || fail "timer is not enabled"
grep -qx "COMPOSE_DIR=$NEW" "$UPDATE_CONFIG" || fail "update config does not point to NEW_DIR"
systemctl start matomo-update.service
[[ $(systemctl show -p Result --value matomo-update.service) == success ]] || fail "first update run failed"
[[ $(tail -n1 "$UPDATE_LOG" | jq -r .event) == no_update ]] || fail "first update run did not report no_update"

echo "migration test passed"
