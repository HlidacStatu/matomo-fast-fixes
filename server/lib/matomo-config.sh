#!/usr/bin/env bash
# Readers for Matomo's config.ini.php shared by the server scripts.

# ini_value FILE SECTION KEY - value from Matomo's config.ini.php.
ini_value() {
  awk -v section="[$2]" -v key="$3" '
    { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
    /^\[/ { in_section = ($0 == section); next }
    in_section {
      line = $0; sub(/^[ \t]+/, "", line)
      n = index(line, "="); if (n == 0) next
      k = substr(line, 1, n - 1); sub(/[ \t]+$/, "", k)
      if (k != key) next
      v = substr(line, n + 1); sub(/^[ \t]+/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}

# ini_has_plugin FILE PLUGIN - PLUGIN is activated in config.ini.php.
ini_has_plugin() {
  awk -v plugin="$2" '
    { sub(/\r$/, "") }
    /^\[/ { in_section = ($0 ~ /^\[Plugins\][ \t]*$/); next }
    in_section && $0 ~ /^Plugins\[\][ \t]*=/ {
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/"/, "", v); sub(/[ \t]+$/, "", v)
      if (v == plugin) { found = 1; exit }
    }
    END { exit !found }' "$1"
}
