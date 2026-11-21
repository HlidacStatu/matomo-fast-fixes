#!/usr/bin/env bash
# Prints the comma-separated list of tags for a published image.
#
#   IMAGE:MAJOR.MINOR.PATCH         e.g. :5.14.3   (moves with security rebuilds)
#   IMAGE:MAJOR.MINOR               e.g. :5.14
#   IMAGE:MAJOR                     e.g. :5        (tracked by the servers)
#   IMAGE:latest
#   IMAGE:MAJOR.MINOR.PATCH-BUILD   e.g. :5.14.3-20261121.42 (immutable, for pinning/rollback)
#
# Usage: scripts/image-tags.sh IMAGE VERSION BUILD_ID
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

[[ $# -eq 3 ]] || die "usage: $0 IMAGE VERSION BUILD_ID"
IMAGE=$1
VERSION=$2
BUILD_ID=$3

is_stable_version "$VERSION" || die "not a stable version: $VERSION"
[[ $BUILD_ID =~ ^[A-Za-z0-9_.]+$ ]] || die "invalid BUILD_ID: $BUILD_ID"

major=${VERSION%%.*}
minor=${VERSION%.*}

printf '%s\n' \
  "$IMAGE:$VERSION" \
  "$IMAGE:$minor" \
  "$IMAGE:$major" \
  "$IMAGE:latest" \
  "$IMAGE:$VERSION-$BUILD_ID" | paste -sd, -
