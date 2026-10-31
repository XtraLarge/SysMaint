#!/usr/bin/env bash
# Woechentlicher Gesamtlauf aller SysMaint-Aufgaben.
#
# Reihenfolge (Reboots ganz am Ende, damit alle anderen Tasks laufende Hosts sehen):
#   1. inventory  tools/sync-proxmox.sh   Inventar mit Proxmox abgleichen
#   2. monitoring tools/compare-monitoring.py Inventar mit Monitoring-Hosts vergleichen
#   3. keys       run-keys.sh full        SSH-Key-Block
#   4. shell      run-shell.sh full       Shell-Baseline
#   5. rsyslog    run-rsyslog.sh full     Log-Weiterleitung
#   6. autofs     run-autofs.sh full      AutoFS-Dateien auf dem Management-Host
#   7. unattended run-unattended.sh audit unattended-upgrades pruefen (nur lesend)
#   8. update     run-update.sh full      Updates, danach geplante Reboots
#
# Ergebnis:
#   logs/weekly/<lauf>/            Logs und Statusdateien je Schritt
#   logs/weekly/<lauf>/summary.txt Zusammenfassung (auch per Mail)
#   logs/last_weekly.status        maschinenlesbarer Gesamtstatus (Monitoring)
#
# Verwendung:
#   ./run-weekly.sh [--jobs N] [--skip SCHRITT[,SCHRITT...]] [--no-mail]
#
# Exit-Code: 0 = OK, 1 = Warnungen, 2 = Fehler

set -uo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$BASE_DIR"
source "$BASE_DIR/lib/common.sh"
# Config exportieren, damit auch die Python-Werkzeuge sie sehen
set -a
if [[ -r /etc/sysmaint/config.sh ]]; then
  # shellcheck source=/dev/null
  source /etc/sysmaint/config.sh
elif [[ -r $BASE_DIR/config.sh ]]; then
  # shellcheck source=/dev/null
  source "$BASE_DIR/config.sh"
fi
set +a

: "${WEEKLY_JOBS:=${DEFAULT_JOBS:-8}}"
: "${WEEKLY_LOG_ROOT:=$BASE_DIR/logs/weekly}"
: "${WEEKLY_KEEP_RUNS:=8}"
: "${WEEKLY_LOCK_FILE:=/run/lock/sysmaint-weekly.lock}"
: "${WEEKLY_MAIL:=1}"
export WEEKLY_LOG_ROOT

SKIP=","
while (( $# > 0 )); do
  case $1 in
    --jobs) shift; WEEKLY_JOBS=${1:?--jobs braucht eine Zahl} ;;
    --skip) shift; SKIP=",${1:?--skip braucht Schrittnamen},";;
    --no-mail) WEEKLY_MAIL=0 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) err "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

exec 9>"$WEEKLY_LOCK_FILE"
if ! flock -n 9; then
  err "Ein anderer Wochenlauf ist noch aktiv ($WEEKLY_LOCK_FILE)."
  exit 2
fi

RUN_ID=$(date +%F_%H%M)
RUN_DIR="$WEEKLY_LOG_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
STEPS_FILE="$RUN_DIR/steps.tsv"
printf 'step\trc\tseconds\n' > "$STEPS_FILE"
date -Is > "$RUN_DIR/started"

exec > >(tee "$RUN_DIR/run-weekly.log") 2>&1
info "Wochenlauf $RUN_ID gestartet, Logs: $RUN_DIR"

run_step() {
  local name=$1
  shift
  if [[ $SKIP == *",$name,"* ]]; then
    info "Schritt $name uebersprungen (--skip)"
    printf '%s\tskip\t0\n' "$name" >> "$STEPS_FILE"
    return 0
  fi
  local start rc
  start=$(date +%s)
  info "=== Schritt $name ==="
  mkdir -p "$RUN_DIR/$name"
  LOG_DIR="$RUN_DIR/$name" "$@" < /dev/null
  rc=$?
  printf '%s\t%s\t%s\n' "$name" "$rc" "$(( $(date +%s) - start ))" >> "$STEPS_FILE"
  info "Schritt $name beendet mit rc=$rc"
  return 0
}

monitor_compare() {
  local out=$RUN_DIR/monitoring/report.txt rc
  "$BASE_DIR/tools/compare-monitoring.py" > "$out"
  rc=$?
  info "Monitoring-Abgleich: $(grep -c . "$out" || true) Befund(e)"
  return "$rc"
}

run_step inventory  "$BASE_DIR/tools/sync-proxmox.sh" --report "$RUN_DIR/inventory/report.txt"
run_step monitoring monitor_compare
run_step keys       "$BASE_DIR/run-keys.sh"       full --jobs "$WEEKLY_JOBS"
run_step shell      "$BASE_DIR/run-shell.sh"      full --jobs "$WEEKLY_JOBS"
run_step rsyslog    "$BASE_DIR/run-rsyslog.sh"    full --jobs "$WEEKLY_JOBS"
run_step autofs     "$BASE_DIR/run-autofs.sh"     full
run_step unattended "$BASE_DIR/run-unattended.sh" audit --jobs "$WEEKLY_JOBS"
run_step update     "$BASE_DIR/run-update.sh"     full --jobs "$WEEKLY_JOBS"

date -Is > "$RUN_DIR/finished"
"$BASE_DIR/tools/weekly-summary.py" "$RUN_DIR"
summary_rc=$?

if [[ $WEEKLY_MAIL == 1 ]]; then
  "$BASE_DIR/tools/send-report.py" "$RUN_DIR/summary.txt" || warn "Bericht konnte nicht gemailt werden"
fi

# alte Laeufe aufraeumen
find "$WEEKLY_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | sort | head -n -"$WEEKLY_KEEP_RUNS" \
  | while read -r old; do rm -rf -- "${WEEKLY_LOG_ROOT:?}/$old"; done

info "Wochenlauf $RUN_ID beendet (Status rc=$summary_rc)"
exit "$summary_rc"
