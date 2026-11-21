#!/usr/bin/env bash
# Validates build.config and prints it as KEY=VALUE lines, ready to be appended
# to $GITHUB_ENV. Usage: scripts/build-config.sh [CONFIG_FILE]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

CONFIG_FILE=${1:-$SCRIPT_DIR/../build.config}

REQUIRED_KEYS=(
  IMAGE_NAME PACKAGE_NAME PLATFORMS TEST_PLATFORM KEEP_PACKAGE_VERSIONS FINGERPRINT_LABEL
  MATOMO_VERSION MATOMO_MAJOR MATOMO_GIT_URL MATOMO_DOWNLOAD_BASE_URL MATOMO_GPG_FINGERPRINT
  GEOIP_MMDB_BASE_URL UNIFONT_URL ALPINE_VERSION
  TRIVY_IMAGE TRIVY_SEVERITY SMOKE_TEST_TIMEOUT_SECONDS
)

load_config "$CONFIG_FILE" "${REQUIRED_KEYS[@]}"

is_stable_version "$MATOMO_VERSION" || die "MATOMO_VERSION is not a stable version: $MATOMO_VERSION"
[[ ${MATOMO_VERSION%%.*} == "$MATOMO_MAJOR" ]] || die "MATOMO_VERSION $MATOMO_VERSION is outside MATOMO_MAJOR $MATOMO_MAJOR"
[[ $IMAGE_NAME == "$(tr '[:upper:]' '[:lower:]' <<<"$IMAGE_NAME")" ]] || die "IMAGE_NAME must be lowercase: $IMAGE_NAME"
[[ ${IMAGE_NAME##*/} == "$PACKAGE_NAME" ]] || die "PACKAGE_NAME must be the last segment of IMAGE_NAME"

for key in "${REQUIRED_KEYS[@]}"; do
  printf '%s=%s\n' "$key" "${!key}"
done
