#!/usr/bin/env bash
# Helpers for working with Matomo release versions (MAJOR.MINOR.PATCH).
# Pre-releases (anything with a suffix such as -rc1, -b2, -b2.20261121...) are
# never considered stable, regardless of how GitHub flags them.

# Reads tag names (one per line) on stdin and prints the stable versions,
# de-duplicated and sorted ascending. A leading "v" is tolerated.
stable_versions() {
  sed -E 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n -u || true
}

# latest_for_major MAJOR < tags
# Prints the newest stable version of the given major line (empty if none).
latest_for_major() {
  local major=$1
  stable_versions | awk -F. -v major="$major" '$1 == major' | tail -n1
}

# is_stable_version VERSION - succeeds when VERSION is a plain MAJOR.MINOR.PATCH.
is_stable_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# version_gt A B - succeeds when version A is strictly greater than version B.
version_gt() {
  local a=$1 b=$2
  [[ $a != "$b" ]] || return 1
  [[ $(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1) == "$a" ]]
}
