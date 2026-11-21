#!/usr/bin/env bats
# Tests of scripts/build-config.sh and scripts/lib/config.sh.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/build-config.sh"
REAL_CONFIG="$BATS_TEST_DIRNAME/../../build.config"

setup() {
  CONFIG="$BATS_TEST_TMPDIR/build.config"
  cp "$REAL_CONFIG" "$CONFIG"
}

@test "the committed build.config is valid" {
  run "$SCRIPT" "$REAL_CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_NAME=ghcr.io/hlidacstatu/matomo"* ]]
  [[ "$output" == *"MATOMO_VERSION="* ]]
}

@test "fails when the config file does not exist" {
  run "$SCRIPT" "$BATS_TEST_TMPDIR/missing.config"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config file not found"* ]]
}

@test "fails fast and lists every missing key" {
  sed -i.bak -e '/^PLATFORMS=/d' -e '/^TRIVY_IMAGE=/d' "$CONFIG"
  run "$SCRIPT" "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PLATFORMS"* ]]
  [[ "$output" == *"TRIVY_IMAGE"* ]]
}

@test "fails when a key is present but empty" {
  sed -i.bak -e 's/^MATOMO_GPG_FINGERPRINT=.*/MATOMO_GPG_FINGERPRINT=/' "$CONFIG"
  run "$SCRIPT" "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MATOMO_GPG_FINGERPRINT"* ]]
}

@test "rejects an uppercase image name (GHCR requirement)" {
  sed -i.bak -e 's|^IMAGE_NAME=.*|IMAGE_NAME=ghcr.io/HlidacStatu/matomo|' "$CONFIG"
  run "$SCRIPT" "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "rejects a version outside the tracked major" {
  sed -i.bak -e 's/^MATOMO_VERSION=.*/MATOMO_VERSION=6.0.0/' "$CONFIG"
  run "$SCRIPT" "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside MATOMO_MAJOR"* ]]
}

@test "rejects a pre-release version" {
  sed -i.bak -e 's/^MATOMO_VERSION=.*/MATOMO_VERSION=5.15.0-rc1/' "$CONFIG"
  run "$SCRIPT" "$CONFIG"
  [ "$status" -ne 0 ]
}
