#!/usr/bin/env bash
# Structured logging shared by the server scripts.
#
# Every event is appended as one JSON line to $LOG_FILE (when set). On stdout
# the same event is printed as JSON (LOG_STDOUT_FORMAT=json, for journald) or
# as a readable line (LOG_STDOUT_FORMAT=text, for interactive use).
# The calling script must set LOG_STDOUT_FORMAT and RUN_ID.

# log LEVEL EVENT MESSAGE [KEY VALUE]...
log() {
  local level=$1 event=$2 message=$3
  shift 3
  local fields='{}'
  while (($# >= 2)); do
    fields=$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$fields")
    shift 2
  done
  local line
  line=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg level "$level" \
    --arg event "$event" \
    --arg message "$message" \
    --arg run_id "$RUN_ID" \
    --argjson fields "$fields" \
    '{ts: $ts, level: $level, event: $event, message: $message, run_id: $run_id} + $fields')
  if [[ ${LOG_STDOUT_FORMAT:?} == text ]]; then
    jq -r '"\(.ts) \(.level | ascii_upcase) \(.event): \(.message)" +
      ([to_entries[] | select(.key | IN("ts", "level", "event", "message", "run_id") | not)
        | " \(.key)=\(.value)"] | join(""))' <<<"$line"
  else
    printf '%s\n' "$line"
  fi
  if [[ -n ${LOG_FILE:-} ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}
