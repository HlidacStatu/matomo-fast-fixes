#!/usr/bin/env bats
# Tests of scripts/image-tags.sh.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/image-tags.sh"

@test "produces version, minor, major, latest and immutable build tags" {
  run "$SCRIPT" ghcr.io/hlidacstatu/matomo 5.14.3 20261121.42
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/hlidacstatu/matomo:5.14.3,ghcr.io/hlidacstatu/matomo:5.14,ghcr.io/hlidacstatu/matomo:5,ghcr.io/hlidacstatu/matomo:latest,ghcr.io/hlidacstatu/matomo:5.14.3-20261121.42" ]
}

@test "rejects a pre-release version" {
  run "$SCRIPT" img 6.0.0-rc2 1
  [ "$status" -ne 0 ]
}

@test "rejects a build id with characters not allowed in tags" {
  run "$SCRIPT" img 5.14.3 'a/b'
  [ "$status" -ne 0 ]
}
