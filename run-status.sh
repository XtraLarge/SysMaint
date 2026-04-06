#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATUS_FILE=${STATUS_FILE:-$BASE_DIR/logs/last_run.status}
LOG_FILE=${LOG_FILE:-$BASE_DIR/logs/last_run.log}

[[ -r $STATUS_FILE ]] || {
  printf 'Keine Statusdatei gefunden: %s\n' "$STATUS_FILE" >&2
  exit 1
}

printf 'Letzte Statusdatei: %s\n' "$STATUS_FILE"
[[ -r $LOG_FILE ]] && printf 'Letzte Logdatei:   %s\n' "$LOG_FILE"
printf '\n'

printf '%-24s %-16s %-4s %-16s %s\n' "System" "IP" "Flag" "Ergebnis" "Detail"
printf '%-24s %-16s %-4s %-16s %s\n' "------------------------" "----------------" "----" "----------------" "------------------------------"

awk -F'|' '
  /^[[:space:]]*#/ { next }
  NF < 5 { next }
  {
    printf "%-24s %-16s %-4s %-16s %s\n", $1, $2, $3, $4, $5
  }
' "$STATUS_FILE"
