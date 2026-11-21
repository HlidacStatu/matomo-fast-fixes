#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests of scripts/lib/version.sh.

setup() {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/version.sh"
}

TAGS='5.14.1
5.14.3
5.14.2
5.9.0
5.10.0
4.16.5
6.0.0-rc2
6.1.0-b2
6.1.0-b2.20261121180336
v5.14.0
latest-tag'

@test "stable_versions drops pre-releases and junk and sorts numerically" {
  run stable_versions <<<"$TAGS"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "4.16.5" ]
  [ "${lines[1]}" = "5.9.0" ]
  [ "${lines[2]}" = "5.10.0" ]
  [ "${lines[${#lines[@]}-1]}" = "5.14.3" ]
  [[ "$output" != *rc* && "$output" != *b2* && "$output" != *latest* ]]
}

@test "stable_versions tolerates a leading v" {
  run stable_versions <<<"$TAGS"
  [[ "$output" == *"5.14.0"* ]]
}

@test "latest_for_major picks the newest release of the major line" {
  run latest_for_major 5 <<<"$TAGS"
  [ "$output" = "5.14.3" ]
}

@test "latest_for_major ignores a newer major that only has pre-releases" {
  run latest_for_major 6 <<<"$TAGS"
  [ "$output" = "" ]
}

@test "latest_for_major prefers 5.10 over 5.9 (numeric, not lexical)" {
  run latest_for_major 5 <<<$'5.9.0\n5.10.0'
  [ "$output" = "5.10.0" ]
}

@test "version_gt compares numerically" {
  version_gt 5.14.3 5.14.1
  version_gt 5.10.0 5.9.9
  run ! version_gt 5.14.1 5.14.1
  run ! version_gt 5.9.0 5.10.0
}

@test "is_stable_version accepts only MAJOR.MINOR.PATCH" {
  is_stable_version 5.14.3
  run ! is_stable_version 6.0.0-rc2
  run ! is_stable_version 5.14
  run ! is_stable_version v5.14.3
}
