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

   Migrating a running crazymax stack: follow [MIGRATION.md](MIGRATION.md)
   (step-by-step, no data loss, about a minute of downtime). In short:
   - keep `MATOMO_DATA_DIR=/data/matomo` - the bind mount layout is the same,
   - set `COMPOSE_PROJECT_NAME` to the old project name (the old directory
     name) or run `docker compose down` in the old directory first,
   - `MYSQL_*` must match the existing database user,
   - `mariadb:10.11` is what `mariadb:10` resolved to, so the data directory
     is reused as is. Root password settings only apply to a new data
     directory; an existing passwordless root stays passwordless - set a
     password manually (`ALTER USER 'root'@'%' IDENTIFIED BY ...`),
   - `redis:4.0` is replaced by `redis:8-alpine`; Redis holds only cache data.

3. **Update script.**

   ```sh
   install -d -m 700 /etc/matomo-update
   install -m 600 /opt/matomo-fast-fixes/server/matomo-update.env.example /etc/matomo-update/matomo-update.env
   # adjust COMPOSE_DIR, BACKUP_DIR, HEALTH_URL, ...
   cp /opt/matomo-fast-fixes/server/systemd/matomo-update.* /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now matomo-update.timer
   ```

   First run by hand: `systemctl start matomo-update.service && journalctl -u matomo-update -n 50`.

### Update script behaviour

`server/matomo-update.sh CONFIG_FILE` - see the header of the script for details.

| Situation | Result | Exit |
|---|---|---|
| no new image | nothing happens (no restart, no backup) | 0 |
| new image, verification passes | deployed, old backups/images pruned | 0 |
| new image, verification fails | rolled back, DB + config restored, image ID blocked | 1 |
| rollback fails | log event `rollback_failed`, backups kept for manual restore | 1 |
| invalid config / missing tools | nothing happens | 2 |

Logs are JSON lines in journald and in `LOG_FILE`, e.g.
`jq 'select(.level != "info")' /var/log/matomo-update/matomo-update.log`.

A rollback discards tracking data written between the backup and the rollback
(typically a few minutes). Blocked images are listed in
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
  `matomo-update.sh` against a local registry (needs Docker; runs in CI).
