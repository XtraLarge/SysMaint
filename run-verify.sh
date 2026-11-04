#!/usr/bin/env bash
# Nachkontrolle des letzten Wochenlaufs (Erreichbarkeit, Logs, Monitoring,
# Backup-Abdeckung). Laeuft einige Stunden nach run-weekly.sh, wenn alle
# Reboots durch sind. Aendert nichts, prueft nur.
#
# Verwendung:
#   ./run-verify.sh [LAUF-VERZEICHNIS] [--no-mail]
#
# Exit-Code: 0 = OK, 1 = Hinweise, 2 = Fehler

set -uo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
set -a
if [[ -r /etc/sysmaint/config.sh ]]; then
  # shellcheck source=/dev/null
  source /etc/sysmaint/config.sh
elif [[ -r $BASE_DIR/config.sh ]]; then
  # shellcheck source=/dev/null
  source "$BASE_DIR/config.sh"
fi
set +a

: "${WEEKLY_MAIL:=1}"
RUN_DIR=""
for arg in "$@"; do
  case $arg in
    --no-mail) WEEKLY_MAIL=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) RUN_DIR=$arg ;;
  esac
done

if [[ -z $RUN_DIR ]]; then
  RUN_DIR=$(find "${WEEKLY_LOG_ROOT:-$BASE_DIR/logs/weekly}" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
fi
[[ -n $RUN_DIR && -d $RUN_DIR ]] || { echo "Kein Wochenlauf gefunden" >&2; exit 2; }

"$BASE_DIR/tools/verify-weekly.py" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/verify.log"
rc=${PIPESTATUS[0]}

if [[ $WEEKLY_MAIL == 1 && -s $RUN_DIR/verify.txt ]]; then
  "$BASE_DIR/tools/send-report.py" "$RUN_DIR/verify.txt" || echo "Bericht konnte nicht gemailt werden" >&2
fi
exit "$rc"
