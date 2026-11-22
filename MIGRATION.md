# Migrating from crazymax/matomo to ghcr.io/hlidacstatu/matomo

This guide moves an existing stack built from the crazymax example
`docker-compose.yml` (services `db`, `redis`, `msmtpd`, `geoip-updater`,
`matomo`, `cron`, bind mounts under `/data/matomo`) to this repository's
`server/compose.yml`. Data is not lost, and Matomo is unavailable only while
the containers are recreated and Matomo starts: under a minute when the
Matomo version stays the same, longer if database migrations have to run.

Why no data is lost:

- The image is the same runtime as crazymax (same paths, `PUID`/`PGID`
  defaults, environment variables and s6 services). Only the build pipeline
  differs.
- All data stays in the same host directories (`/data/matomo/db`,
  `/data/matomo/web`, `/data/matomo/geoip-updater`), which are mounted
  unchanged.
- A full backup is taken while the old stack is still running, and you have a
  rollback path at every step.

Downtime is minimal because:

- everything that can be prepared in advance (files, image pulls, backup)
  is done while the old stack keeps serving,
- the switch itself is a single `docker compose up -d --wait`, which recreates
  the containers in place.

Tracking requests sent while Matomo is down (tens of seconds) are lost, because
the JavaScript tracker does not retry. Pick a low-traffic time for step 5.

Commands assume the old stack lives in `/opt/matomo` and runs as root. Replace
the paths if yours differ.

## Automated migration (recommended)

`server/migrate-from-crazymax.sh` performs the steps below in one run and
rolls back automatically if the new stack does not come up.

```sh
git clone https://github.com/HlidacStatu/matomo-fast-fixes /opt/matomo-fast-fixes
cd /opt/matomo-fast-fixes/server

# 1. Checks only, shows the generated configuration, changes nothing:
./migrate-from-crazymax.sh --dry-run /opt/matomo /opt/matomo-hs

# 2. The migration itself (asks before the switch):
./migrate-from-crazymax.sh /opt/matomo /opt/matomo-hs
```

Arguments:
- `OLD_DIR` (`/opt/matomo`) is the directory with the running stack's
  `docker-compose.yml` and env files.
- `NEW_DIR` (`/opt/matomo-hs`) is an empty or missing directory for the new
  `compose.yml` and `.env`.

### Principle: the migration changes orchestration, not versions

The switch runs exactly the software the old stack runs:
- MariaDB, Redis, msmtpd and geoip-updater on the old images, pinned by
  digest,
- Matomo on this repository's image of the *same* Matomo version (for
  example `ghcr.io/hlidacstatu/matomo:5.14.1`).

The database is therefore not migrated, and a failed switch can return to
the old stack without restoring anything. Tracking data written in the
meantime is kept.

When the switch succeeds, the script points `.env` at the tracked lines
(`ghcr.io/hlidacstatu/matomo:5`, `mariadb:<running major.minor>`,
`redis:8-alpine`, ...). The next `matomo-update.sh` run (systemd timer)
upgrades to them with its own backup, verification and rollback.

If the registry has no image of the running Matomo version, the switch uses
the tracked image and therefore also upgrades Matomo. The plan prints a
warning in that case.

### What the script does

1. **Checks** the following and stops with a clear message if something does
   not hold:
   - Docker Engine 25 or newer,
   - all six services are running,
   - only the default network is used, no extra labels, no `container_name`,
     no command or entrypoint overrides (the `db` command must equal the one
     in `compose.yml`),
   - data is only in bind mounts, and redis/msmtpd have no volumes,
   - the published port matches the running container,
   - `config.ini.php` uses the `db` service's credentials (pre-flight check
     below),
   - QueuedTracking is not active,
   - the Matomo major version matches.
2. **Generates `NEW_DIR`** from the *running* containers. It reads their
   environment (minus image defaults), bind mounts and published port, so
   values from `environment:`, `env_file:` and shell variables are all carried
   over exactly.
   - `COMPOSE_*` variables and `.env` keys exported in your shell are ignored.
   - The resolved compose model is checked against the plan.
3. **Pulls the Matomo image for the switch** and shows the plan. Tracked
   images are not pulled here, so tags used by the old compose file do not
   move. The first `matomo-update.sh` run pulls them.
4. **Asks for confirmation.** Use `--yes` for non-interactive runs. If you
   decline, or anything fails or is interrupted before the switch, the files
   the script wrote are removed again: a `NEW_DIR` it created is deleted, an
   existing empty one is emptied. The run's log then remains only on stdout.
   A pull error other than "tag not found" (network, rate limit) stops the
   migration instead of switching to a newer Matomo.
5. **Takes a backup.** It stops cron, checks free space (at least the size of
   the database), dumps the database and archives `config/` into
   `<web dir>/../backups`.
   - The dump check requires `-- Dump completed` and at least one table.
   - Files are created with mode 600, the directory with 700.
   - A schema fingerprint is recorded as well (see `server/lib/db.sh`).
6. **Switches over (the downtime starts).** It moves every file of `OLD_DIR`
   except data directories into `OLD_DIR/_old_` and runs
   `docker compose up --pull never --wait` in `NEW_DIR` for every service
   except cron. This recreates the containers in place.
7. **Verifies the new stack:** HTTP on `/matomo.php`, the Matomo version and
   `core:update`. Then it starts cron, and the downtime ends.
8. **Updates `.env` and installs the timer.** It points `.env` at the tracked
   image lines and installs the update timer (`server/install-timer.sh`).
   - The new `.env` is built and validated next to the old one and then
     renamed, so it never holds only some of the new lines.
   - The timer setup refuses an existing config that points to another
     stack; a config of the same stack gets the new values.
   - Finally it prints where everything is.

   From now on `.env` is ahead of the running containers until the first
   `matomo-update.sh` run deploys the tracked images. **Do not run a plain
   `docker compose up -d` in `NEW_DIR` before that**: it would pull and
   recreate the containers without a backup. Run
   `systemctl start matomo-update.service` instead (backup, verification,
   rollback).

**If step 6 or 7 fails, or the script is interrupted (Ctrl+C, SIGTERM, an
unexpected error), it rolls back automatically.** Further signals are ignored
while the rollback runs, so it is not cut off half way.

1. It removes the new containers and verifies that none is left.
2. It moves the files back from `_old_` and re-tags the old images.
3. It starts the old database and decides whether to restore the dump,
   discarding data tracked since the backup:
   - **always** when the switch upgraded Matomo: its migrations may have
     changed data, or stopped before they changed the schema, which a
     fingerprint cannot see. Tracking was down during the switch anyway, so
     little is lost;
   - with the same Matomo version, only when the schema fingerprint (tables,
     columns, indexes, recorded schema versions) changed or cannot be read.
     Otherwise all data is kept.
4. It replaces `config/` with the archived copy, starts the old stack with
   `--pull never` and checks it over HTTP.

**Downtime** lasts from step 6 to the end of step 7: recreating the containers
plus Matomo's start. With the same Matomo version this is typically under a
minute: 31 s in the CI test, which uses a Matomo that is not installed yet.
An installed Matomo also runs `core:update` on start, which adds some time.
If the switch also upgrades Matomo, it includes the database migrations,
which can take much longer on a large database.

**Power loss during steps 6–7** is not recovered automatically. In that case:
- `OLD_DIR/_old_` and `NEW_DIR/migration.log` show how far the migration got.
- To go back, move the files from `_old_` to `OLD_DIR`, then run
  `docker compose up -d` there.
- To finish the migration instead, run
  `docker compose up -d --pull never --wait` in `NEW_DIR`. Its `.env` still
  pins the old images. Then run `server/install-timer.sh` with the arguments
  that `migration.log` shows (event `timer_failed` shows the exact command,
  the plan its values); the first timer run upgrades nothing until you point
  `.env` at the tracked lines (see `.env.example`).

Exit codes:

| Code | Meaning |
|---|---|
| `0` | migrated |
| `1` | failed and rolled back, or nothing was changed |
| `2` | rollback failed: see `NEW_DIR/migration.log` and the backups |
| `3` | migrated and the new stack runs, but finishing failed: `.env` could not be pointed at the tracked lines, or the timer could not be installed (see the log) |

Options:
- `--start-period DURATION` sets `MATOMO_START_PERIOD`, the grace period for
  DB migrations. Raise it for very large databases.
- `--wait-timeout SECONDS` sets how long the switch, and later
  `matomo-update.sh`, may wait for a healthy stack. It must be longer than
  the start period.
- `--matomo-image IMAGE` sets the Matomo image the stack tracks after the
  migration.

Still check the database credentials (step 0) before the first run. The script
refuses to continue on a mismatch, but fixing it is up to you. Afterwards do
the follow-up hardening (step 8).

The rest of this document is the same procedure done by hand, for when you
want to run or inspect each step yourself.

---

## 0. Pre-flight checks (no downtime)

```sh
cd /opt/matomo
docker compose ls                                   # note NAME and CONFIG FILES
docker compose ps                                   # all services up?
docker compose exec matomo console core:version     # current Matomo version
docker compose exec db mariadb --version            # current MariaDB version
docker compose exec redis redis-server --version
df -h /data/matomo                                  # free space for a DB dump
docker version --format '{{.Server.Version}}'       # must be 25 or newer
command -v jq flock curl gzip                       # needed by matomo-update.sh
ls -la /opt/matomo/.env 2>/dev/null                 # an existing .env would be replaced in step 5
grep -A12 '^\[database\]' /data/matomo/web/config/config.ini.php
```

Check these before you continue:

- **Database credentials Matomo really uses (stop if they differ).** In the
  `[database]` section, `host` must be `db`, `username` must be the old
  `MYSQL_USER`, and `dbname` must be the old `MYSQL_DATABASE`.
  - The backups (step 3 and `matomo-update.sh`) dump `MYSQL_DATABASE` as
    `MYSQL_USER`. If Matomo was installed against `root` or another database,
    those backups would be empty.
  - The root password change in step 8 would also cut Matomo off.
  - Fix this first: create a dedicated user with access to Matomo's database
    and switch `config.ini.php` to it. Alternatively, set `MYSQL_*` in `.env`
    to match.
- **Docker Engine 25 or newer.** `compose.yml` uses the healthcheck setting
  `start_interval`. An older engine fails only at `up`, in the middle of the
  downtime window.
- **Existing `.env` in `/opt/matomo`.** If there is one, merge its content into
  the new `.env` in step 2. Step 5 replaces it.
- **Matomo version.** The new image ships the latest `5.x` release. If you run
  4.x, first read Matomo's
  [4 to 5 upgrade notes](https://matomo.org/faq/how-to-update/how-to-upgrade-to-matomo-5/)
  and check your marketplace plugins in `/data/matomo/web/plugins` for 5.x
  compatibility.
- **MariaDB version.** The new stack pins `mariadb:10.11`. A long-running
  `mariadb:10` that was never re-pulled can be older (10.4 to 10.6). That is
  fine: `MARIADB_AUTO_UPGRADE=1` runs `mariadb-upgrade` on first start. The
  backup from step 3 is what makes this safe.
- **Project name.** Note the `NAME` from `docker compose ls`. It is usually
  the directory name, for example `matomo`. The new stack must use the same
  name so that compose replaces the existing containers instead of starting a
  second stack next to them, which would fail on port 8000.
- **Free disk space.** You need at least the size of the Matomo database,
  roughly `du -sh /data/matomo/db`, for the compressed dump.

## 1. Repository (no downtime)

Both the repository and the GHCR package `ghcr.io/hlidacstatu/matomo` are
public, so neither the clone nor the image pulls need a token or
`docker login`.

```sh
git clone https://github.com/HlidacStatu/matomo-fast-fixes /opt/matomo-fast-fixes
```

## 2. Prepare the new configuration next to the old one (no downtime)

Prepare the new files in a staging directory so the running stack is not
touched yet:

```sh
mkdir -p /opt/matomo/.new
cd /opt/matomo/.new
cp /opt/matomo-fast-fixes/server/compose.yml .
cp /opt/matomo-fast-fixes/server/.env.example .env
# Reuse the existing service configuration unchanged:
cp ../matomo.env ../msmtpd.env ../geoip-updater.env .
chmod 600 .env msmtpd.env geoip-updater.env
```

Edit `.env`:

| Key | Value |
|---|---|
| `COMPOSE_PROJECT_NAME` | the `NAME` from step 0 (e.g. `matomo`) |
| `MATOMO_DB_DIR`, `MATOMO_WEB_DIR`, `MATOMO_GEOIP_DIR` | the old bind mount sources (`/data/matomo/db`, `/data/matomo/web`, `/data/matomo/geoip-updater`) |
| `MARIADB_IMAGE` | `mariadb:<major.minor>` of the running server (`SELECT VERSION()`), so the data directory is not upgraded during the migration |
| `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` | exactly the values from the old `docker-compose.yml` |
| `TZ` | your timezone, e.g. `Europe/Prague` (the old file passed an empty `TZ` from the shell) |
| `CRON_ARCHIVE`, `ARCHIVE_OPTIONS` | the values from the old `cron` service |
| `MATOMO_PUBLISHED_PORT` | `8000` (the old published port) |

Validate the new configuration and pre-pull all images. Pulling does not
affect the running containers:

```sh
docker compose config >/dev/null && echo "config OK"
docker compose pull
```

If `pull` fails with `denied` or `unauthorized`, check that `MATOMO_IMAGE` in
`.env` is spelled exactly `ghcr.io/hlidacstatu/matomo:5` (lowercase).

Never run `docker compose up` in `.new`: it uses the same project name as the
running stack and would replace its containers before the backup is taken.

## 3. Backup (no downtime)

Take the backup while the old stack is running. `--single-transaction` gives a
consistent InnoDB snapshot without locking Matomo.

```sh
mkdir -p /data/matomo/backups
cd /opt/matomo
TS=$(date -u +%Y%m%dT%H%M%SZ)

docker compose exec -T db sh -c \
  'MYSQL_PWD="$MYSQL_PASSWORD" exec mariadb-dump --single-transaction --quick \
     --add-drop-database -u"$MYSQL_USER" --databases "$MYSQL_DATABASE"' \
  | gzip > /data/matomo/backups/matomo-db-$TS-pre-migration.sql.gz

# The dump must end with "-- Dump completed" and contain Matomo's tables
# (an empty database would also "complete"):
gzip -dc /data/matomo/backups/matomo-db-$TS-pre-migration.sql.gz | tail -n1
gzip -dc /data/matomo/backups/matomo-db-$TS-pre-migration.sql.gz | grep -c '^CREATE TABLE'

tar -C /data/matomo/web -czf /data/matomo/backups/matomo-config-$TS-pre-migration.tar.gz config
cp docker-compose.yml /data/matomo/backups/docker-compose-crazymax-$TS.yml
```

Do not continue unless the last line of the dump reads `-- Dump completed`
and the table count is in the dozens (a Matomo install has 30+ tables).

The dump plus the unchanged bind mounts are enough to get back to the old
state.

## 4. Stop archiving (no downtime for visitors)

Stop the cron sidecar so that no archiving run overlaps with the switch and
the database migrations:

```sh
cd /opt/matomo
docker compose stop cron
```

## 5. Switch (downtime starts here)

Replace the old compose file with the new one and recreate the stack.
Services keep their names and the project name is the same, so compose
replaces the old containers in place.

```sh
cd /opt/matomo
mv docker-compose.yml docker-compose.crazymax.yml.disabled
mv .new/compose.yml .new/.env .
rm -rf .new          # its *.env files are copies of the ones already in /opt/matomo

docker compose up -d --wait --wait-timeout 1800
```

`--wait` returns once `db` and `redis` are healthy and `matomo` has finished
`core:update` (database migrations) and answers its healthcheck. Downtime ends
when it returns. If the old file is named `docker-compose.yaml` or
`compose.yaml`, move it away the same way: compose must find only the new
`compose.yml`.

## 6. Verify

```sh
docker compose ps                                       # everything Up / healthy
docker compose exec matomo console core:version         # expected 5.x version
docker compose exec matomo console core:update --yes --no-interaction   # "Everything is already up to date"
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/       # 200 or 302
docker compose logs --tail 50 matomo
docker compose logs --tail 20 cron                      # archiving scheduled
docker compose exec redis redis-cli ping                # PONG
```

Then check in the Matomo UI:

- you can log in,
- **Visitors > Visits Log** shows new visits arriving,
- **Administration > System Check** has no new errors (GeoIP, mail, cache).

## 7. Enable automatic updates

```sh
/opt/matomo-fast-fixes/server/install-timer.sh /opt/matomo /data/matomo/backups http://127.0.0.1:8000/matomo.php 2400
systemctl start matomo-update.service      # first run by hand
journalctl -u matomo-update -n 20          # expect event "no_update"
```

`install-timer.sh` creates `/etc/matomo-update/matomo-update.env`. It keeps an
existing file only if that file already points to the same `COMPOSE_DIR`, installs the systemd units with the real script path and enables
the timer.

## 8. Follow-up hardening (separate maintenance windows)

- **Root password.** The old stack ran with `MYSQL_ALLOW_EMPTY_PASSWORD=yes`.
  The setting is gone from the new compose file, but the existing root account
  in the data directory still has no password. Set one:

  ```sh
  docker compose exec db mariadb -uroot -e \
    "ALTER USER 'root'@'localhost' IDENTIFIED BY '<strong password>'; \
     ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '<strong password>';"
  ```

- **MariaDB LTS.** `10.11` is supported until 2028. Moving to `11.4` or `11.8`
  means changing `MARIADB_IMAGE` in `.env`, taking a backup as in step 3 and
  running `docker compose up -d --wait`.
- **Cleanup.** After a few days without problems, delete
  `docker-compose.crazymax.yml.disabled` and the `*-pre-migration*` backups.

---

## Rollback

### Before step 5

Nothing has changed yet. Start archiving again:

```sh
docker compose start cron
```

### After step 5

The new Matomo may already have migrated the database, so restore the backup
together with the old images:

```sh
cd /opt/matomo
docker compose down                                   # stops the new stack, data stays in /data/matomo
mv compose.yml compose.hlidacstatu.yml.disabled
mv .env .env.hlidacstatu.disabled
mv docker-compose.crazymax.yml.disabled docker-compose.yml

docker compose up -d db                               # old MariaDB image
sleep 20                                              # the old file has no healthcheck
gzip -dc /data/matomo/backups/matomo-db-<TS>-pre-migration.sql.gz | \
  docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mariadb -u"$MYSQL_USER"'
tar -C /data/matomo/web -xzf /data/matomo/backups/matomo-config-<TS>-pre-migration.tar.gz
docker compose up -d
```

Tracking data collected between step 3 and the rollback is discarded by the
restore.

If MariaDB was upgraded during the switch (an old 10.x moved to 10.11), keep
`image: mariadb:10.11` in the old file for the rollback. An older MariaDB
cannot reliably open a data directory that a newer version has upgraded.
