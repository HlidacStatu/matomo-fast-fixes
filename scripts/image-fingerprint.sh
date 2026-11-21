#!/usr/bin/env bash
# Prints a content fingerprint (sha256) of a locally available image.
#
# Image digests change on every rebuild even when nothing changed, so the daily
# security rebuild compares this fingerprint instead. It covers everything that
# can change between rebuilds of the same commit or that a commit can change:
#   - every installed Alpine package with its exact version (security patches),
#   - the Matomo version,
#   - the gosu binary,
#   - all files shipped from rootfs/ (s6 services, scripts, config templates).
# The fallback GeoLite2 databases are deliberately excluded: they change often,
# are overridden by geoip-updater at runtime and must not trigger a release.
#
# Usage: scripts/image-fingerprint.sh IMAGE
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 IMAGE" >&2; exit 1; }
IMAGE=$1

docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  set -eu
  apk info -v | sort
  grep "const VERSION = " /var/www/matomo/core/Version.php
  sha256sum /usr/local/bin/gosu
  find /etc/s6-overlay /tpls /usr/local/bin /etc/php*/conf.d -type f | sort | xargs sha256sum
' | sha256sum | cut -d' ' -f1
