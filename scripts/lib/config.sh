#!/usr/bin/env bash
# Shared helpers for loading KEY=VALUE configuration files.

# Prints an error message to stderr and exits.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# load_config FILE KEY...
# Sources FILE (exporting every assignment) and verifies that each listed KEY
# is set and non-empty. Fails fast with a list of all missing keys.
load_config() {
  local file=$1
  shift
  [[ -f $file ]] || die "config file not found: $file"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  local key
  local -a missing=()
  for key in "$@"; do
    [[ -n ${!key:-} ]] || missing+=("$key")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required config in $file: ${missing[*]}"
  fi
}
