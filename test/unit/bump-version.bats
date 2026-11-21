#!/usr/bin/env bats
# Tests of scripts/bump-version.sh.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/bump-version.sh"

setup() {
  CONFIG="$BATS_TEST_TMPDIR/build.config"
  printf '# comment\nMATOMO_VERSION=5.14.1\nMATOMO_MAJOR=5\nOTHER=value\n' >"$CONFIG"
}

@test "bumps the version and keeps the rest of the file" {
  run "$SCRIPT" 5.14.3 "$CONFIG"
  [ "$status" -eq 0 ]
  grep -qx 'MATOMO_VERSION=5.14.3' "$CONFIG"
  grep -qx 'OTHER=value' "$CONFIG"
  grep -qx '# comment' "$CONFIG"
  [ "$(wc -l <"$CONFIG" | tr -d ' ')" -eq 4 ]
}

@test "refuses a downgrade" {
  run "$SCRIPT" 5.14.0 "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qx 'MATOMO_VERSION=5.14.1' "$CONFIG"
}

@test "refuses the same version" {
  run "$SCRIPT" 5.14.1 "$CONFIG"
  [ "$status" -ne 0 ]
}

@test "refuses a pre-release" {
  run "$SCRIPT" 5.15.0-rc1 "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qx 'MATOMO_VERSION=5.14.1' "$CONFIG"
}

@test "refuses a new major" {
  run "$SCRIPT" 6.0.0 "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside MATOMO_MAJOR"* ]]
}

@test "requires a version argument" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
