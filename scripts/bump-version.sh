#!/usr/bin/env bash
# Sets MATOMO_VERSION in build.config to NEW_VERSION.
# Refuses pre-releases, downgrades and versions outside MATOMO_MAJOR.
# Usage: scripts/bump-version.sh NEW_VERSION [CONFIG_FILE]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

[[ $# -ge 1 ]] || die "usage: $0 NEW_VERSION [CONFIG_FILE]"
NEW_VERSION=$1
CONFIG_FILE=${2:-$SCRIPT_DIR/../build.config}

load_config "$CONFIG_FILE" MATOMO_VERSION MATOMO_MAJOR

is_stable_version "$NEW_VERSION" || die "not a stable version: $NEW_VERSION"
[[ ${NEW_VERSION%%.*} == "$MATOMO_MAJOR" ]] || die "$NEW_VERSION is outside MATOMO_MAJOR $MATOMO_MAJOR"
version_gt "$NEW_VERSION" "$MATOMO_VERSION" || die "$NEW_VERSION is not newer than $MATOMO_VERSION"

[[ $(grep -c '^MATOMO_VERSION=' "$CONFIG_FILE") -eq 1 ]] || die "expected exactly one MATOMO_VERSION line in $CONFIG_FILE"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed -E "s/^MATOMO_VERSION=.*/MATOMO_VERSION=${NEW_VERSION}/" "$CONFIG_FILE" >"$tmp"
cat "$tmp" >"$CONFIG_FILE"
echo "MATOMO_VERSION: $MATOMO_VERSION -> $NEW_VERSION"
