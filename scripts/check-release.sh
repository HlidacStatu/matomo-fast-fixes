#!/usr/bin/env bash
# Checks whether a newer stable Matomo release exists within MATOMO_MAJOR.
#
# Release tags are read with `git ls-remote` (one request, no API pagination,
# not affected by the daily nightly pre-releases). A version is only reported
# as available once both its tarball and its GPG signature are downloadable,
# because the git tag can appear before the build artifacts are uploaded.
#
# Usage: scripts/check-release.sh [CONFIG_FILE]
# Prints KEY=VALUE lines suitable for $GITHUB_OUTPUT:
#   current, latest, update_available (true|false), newer_major (version or empty)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

CONFIG_FILE=${1:-$SCRIPT_DIR/../build.config}
load_config "$CONFIG_FILE" MATOMO_VERSION MATOMO_MAJOR MATOMO_GIT_URL MATOMO_DOWNLOAD_BASE_URL

# Succeeds when the release tarball and its signature both return HTTP 2xx.
artifacts_published() {
  local version=$1 suffix
  for suffix in tar.gz tar.gz.asc; do
    curl -fsSI -o /dev/null "${MATOMO_DOWNLOAD_BASE_URL}/matomo-${version}.${suffix}" || return 1
  done
}

tags=$(git ls-remote --tags --refs "$MATOMO_GIT_URL" | awk '{ sub("^refs/tags/", "", $2); print $2 }')
[[ -n $tags ]] || die "no tags received from $MATOMO_GIT_URL"

latest=$(latest_for_major "$MATOMO_MAJOR" <<<"$tags")
[[ -n $latest ]] || die "no stable release found for major $MATOMO_MAJOR"

newest_overall=$(stable_versions <<<"$tags" | tail -n1)
newer_major=""
if ((${newest_overall%%.*} > MATOMO_MAJOR)); then
  newer_major=$newest_overall
fi

update_available=false
if version_gt "$latest" "$MATOMO_VERSION"; then
  if artifacts_published "$latest"; then
    update_available=true
  else
    echo "Matomo $latest is tagged but its tarball/signature is not published yet" >&2
  fi
fi

printf 'current=%s\nlatest=%s\nupdate_available=%s\nnewer_major=%s\n' \
  "$MATOMO_VERSION" "$latest" "$update_available" "$newer_major"
