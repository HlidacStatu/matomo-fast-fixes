# matomo-fast-fixes

Matomo Docker image based on [crazy-max/docker-matomo](https://github.com/crazy-max/docker-matomo)
(same runtime: Alpine, nginx, PHP-FPM, s6-overlay, cron sidecar, same environment
variables), but rebuilt automatically:

- **new Matomo release** of the tracked major line: built, tested and published
  within ~3 hours, deployed on the servers within 24 hours,
- **security patches** of everything inside the image (Alpine packages: PHP,
  nginx, OpenSSL, musl, ...): fresh rebuild every night, published only when a
  package actually changed,
- **other services** of the stack (MariaDB, Redis, msmtpd, geoip-updater) use
  tags of supported release lines and are pulled by the server update script.

Image: `ghcr.io/hlidacstatu/matomo` with tags `5.14.3`, `5.14`, `5`, `latest`
and an immutable `5.14.3-<date>.<run>` per build. Servers track `:5`.

## How it works

```
GitHub Actions                                   Server (systemd timer, 2x a day)
--------------                                   --------------------------------
release-check   every 3 h                        matomo-update.sh
  git ls-remote matomo-org/matomo                  docker compose pull
  newer 5.x.y + tarball + signature?               nothing new -> exit
  -> bump build.config on a branch                 backup: DB dump + /data/config
  -> build-publish (always)                        stop cron, up --wait, verify
  -> fast-forward main                             (HTTP, version, core:update)
                                                   start cron
security-rebuild   daily, no cache                 failure -> re-tag old images,
  -> build-publish (if content changed)              restore DB + config, block
                                                     the failed image ID
ci   push / PR
  shellcheck, bats, integration test
  -> build-publish (if-changed / never)

build-publish
  build candidate -> smoke test -> Trivy report -> fingerprint
  -> compare with published image -> push -> verify -> prune old versions
```

- The Matomo tarball is verified against the release signing key committed in
  `keys/` (fingerprint asserted in `build.config`).
- "Changed" is decided by a content fingerprint (installed package versions,
  Matomo version, gosu, rootfs files), not by image digests, which change on
  every rebuild.
- Pre-releases (`-rc`, `-b`, nightlies) and new major versions are never picked
  up automatically. A new major is announced as a workflow warning; switching
  is a manual change of `MATOMO_MAJOR`/`MATOMO_VERSION` in `build.config` and of
  `MATOMO_IMAGE` on the servers.
- Trivy findings are reported in the job summary but do not block publishing.

All build settings live in [`build.config`](build.config). Cron schedules are in
the workflow files because GitHub cannot read them from elsewhere.

## Server installation

Requirements: Docker Engine 25+ with the compose plugin (healthcheck
`start_interval`), `jq`, `flock` (util-linux), `curl`, `gzip`.

The repository and the image are public: no token or `docker login` is
needed on the servers.

1. **Scripts.**

   ```sh
   git clone https://github.com/HlidacStatu/matomo-fast-fixes /opt/matomo-fast-fixes
   ```

2. **Stack.** Put `server/compose.yml` into the stack directory (e.g.
   `/opt/matomo`) and create the configuration from the examples:

   ```sh
   cd /opt/matomo
   cp /opt/matomo-fast-fixes/server/compose.yml .
   cp /opt/matomo-fast-fixes/server/.env.example .env
   cp /opt/matomo-fast-fixes/server/matomo.env.example matomo.env
   cp /opt/matomo-fast-fixes/server/msmtpd.env.example msmtpd.env
   cp /opt/matomo-fast-fixes/server/geoip-updater.env.example geoip-updater.env
   chmod 600 .env msmtpd.env geoip-updater.env
   ```

   **Migrating a running crazymax stack:** do not do this by hand, run
   `server/migrate-from-crazymax.sh OLD_DIR NEW_DIR` instead. It generates
   this configuration from the running containers, keeps the data in place,
   moves the old files to `OLD_DIR/_old_`, rolls back automatically on
   failure and installs the timer from step 3. The switch keeps all software
   versions (database untouched); the timer upgrades afterwards. Downtime is
   typically under a minute.
   Details and the manual procedure are in [MIGRATION.md](MIGRATION.md).

3. **Update script.**

   ```sh
   /opt/matomo-fast-fixes/server/install-timer.sh /opt/matomo /data/matomo/backups http://127.0.0.1:8000/matomo.php 2400
   ```

   Arguments: `COMPOSE_DIR BACKUP_DIR HEALTH_URL WAIT_TIMEOUT_SECONDS`. This
   creates `/etc/matomo-update/matomo-update.env` from the example (an
   existing file is kept only if it points to the same `COMPOSE_DIR`; adjust
   the remaining values there), installs the
   systemd units with the real path of this checkout and enables the timer.

   First run by hand: `systemctl start matomo-update.service && journalctl -u matomo-update -n 50`.

### Update script behaviour

`server/matomo-update.sh CONFIG_FILE` - see the header of the script for details.

| Situation | Result | Exit |
|---|---|---|
| no new image | nothing happens (no restart, no backup) | 0 |
| new image, verification passes | deployed, old backups/images pruned | 0 |
| new image, verification fails or run interrupted | rolled back to the previous images, config restored, DB restored only if its schema changed, image ID blocked | 1 |
| rollback fails | log event `rollback_failed`, backups kept for manual restore | 1 |
| invalid config / missing tools | nothing happens | 2 |

Logs are JSON lines in journald and in `LOG_FILE`, e.g.
`jq 'select(.level != "info")' /var/log/matomo-update/matomo-update.log`.

A rollback restores the database dump only when the failed update changed
the schema (Matomo migrations ran; see `server/lib/db.sh`). Only then is the
tracking data written between the backup and the rollback (typically a few
minutes) discarded. Before a dump the script checks that the backup
filesystem has at least as much free space as the database. Containers are
always started with `up --pull never`, so a rollback is not undone by a pull
of a `latest` tag. Blocked images are listed in
`$STATE_DIR/blocked-images`; delete a line to allow a retry of that image.

**Manual rollback** to a specific build: set `MATOMO_IMAGE` in `.env` to an
immutable tag (e.g. `ghcr.io/hlidacstatu/matomo:5.14.1-20261021.123.1`),
restore the matching backup from `BACKUP_DIR` if the DB was migrated, then
`docker compose up -d`.

## Maintenance

- **Upstream changes** (crazymax): `Dockerfile` and `rootfs/` are taken from
  upstream with the modifications listed at the top of the `Dockerfile`.
  Review upstream changes when moving to a new Alpine branch (PHP package
  names change, e.g. `php85`).
- **New Alpine branch**: change `ALPINE_VERSION` (and PHP package names if
  needed) in a pull request; CI builds and tests it.
- **GitHub Actions** are pinned by SHA; Dependabot proposes updates.
- **Build time**: one platform (`linux/amd64`) keeps the daily rebuild short;
  each extra platform in `PLATFORMS` is built under QEMU. `KEEP_PACKAGE_VERSIONS`
  limits the number of image versions kept in GHCR.

## Tests

- `bats test/unit` - unit tests of the scripts,
- `test/smoke/run.sh IMAGE VERSION TIMEOUT` - smoke test of an image,
- `test/integration/run.sh IMAGE` - full update, rollback and block cycle of
  `matomo-update.sh` against a local registry (needs Docker; runs in CI),
- `sudo test/migration/run.sh IMAGE` - migration of a real crazymax stack:
  dry run, automatic rollback, successful migration, timer installation and
  first update run (needs Docker and systemd; runs in CI).
