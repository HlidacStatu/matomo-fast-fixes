#!/usr/bin/env bash
# Host-side helpers shared by the server scripts.

# free_bytes DIR - free space of DIR's filesystem in bytes. Computed in bash:
# awk (mawk 1.3.4 on Ubuntu 22.04) prints large products in exponent notation,
# which bash arithmetic rejects and an `if ((...))` would treat as "false".
free_bytes() {
  local kb
  kb=$(df -Pk "$1" | awk 'NR == 2 { print $4 }') || return 1
  [[ $kb =~ ^[0-9]+$ ]] || return 1
  echo $((kb * 1024))
}

# has_enough_space DIR NEEDED_BYTES - fails (closed) when the values are not
# integers or the free space is smaller. Prints the free bytes.
has_enough_space() {
  local free
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  free=$(free_bytes "$1") || return 1
  echo "$free"
  ((free >= $2))
}

# dotenv_keys FILE - keys a compose .env file defines, also in the forms
# `KEY = value` and `export KEY=value` that compose accepts.
dotenv_keys() {
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$1"
}

# normalize_reference REF - Docker's canonical form of an image reference
# (crazymax/matomo == docker.io/crazymax/matomo:latest, redis ==
# docker.io/library/redis:latest), so that aliases compare equal.
normalize_reference() {
  local ref=$1 digest="" name first
  if [[ $ref == *@* ]]; then
    digest="@${ref#*@}"
    ref=${ref%%@*}
  fi
  name=$ref
  first=${name%%/*}
  if [[ $name != */* || ($first != *.* && $first != *:* && $first != localhost) ]]; then
    [[ $name == */* ]] || name="library/$name"
    name="docker.io/$name"
  fi
  if [[ -z $digest && ${name##*/} != *:* ]]; then
    name="$name:latest"
  fi
  printf '%s%s\n' "$name" "$digest"
}

# conflicting_shared_images - reads "SERVICE REFERENCE IMAGE_ID" lines and
# prints every (normalized) reference that services share while running
# different image IDs. Re-tagging such a reference on rollback can restore
# only one of them.
conflicting_shared_images() {
  local svc ref id
  while read -r svc ref id; do
    [[ -n $svc ]] || continue
    printf '%s %s %s\n' "$svc" "$(normalize_reference "$ref")" "$id"
  done | awk '{ if (($2 in id) && id[$2] != $3) bad[$2] = 1; id[$2] = $3 }
    END { for (r in bad) print r }'
}

# is_missing_tag_error PULL_OUTPUT - succeeds when `docker pull` failed only
# because the tag does not exist (as opposed to network or registry errors).
is_missing_tag_error() {
  grep -qE 'manifest unknown|: not found$' <<<"$1"
}
