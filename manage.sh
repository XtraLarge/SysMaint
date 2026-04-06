#!/usr/bin/env bash
# Zentrale Steuerung aller Verwaltungsfunktionen.
# Aufruf: ./manage.sh <FLAG> <TASK_SCRIPT> [optionen] [-- task-argumente]

set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$BASE_DIR"

DEFAULT_SYSTEMS_FILE=$BASE_DIR/.Systems.sh
if [[ -r /etc/sysmaint/.Systems.sh ]]; then
  DEFAULT_SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
fi

: "${SYSTEMS_FILE:=$DEFAULT_SYSTEMS_FILE}"
: "${LOG_DIR:=$BASE_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/last_run.log"
STATUS_FILE="$LOG_DIR/last_run.status"
REBOOT_QUEUE_FILE=$(mktemp)
trap 'rm -f "$REBOOT_QUEUE_FILE"' EXIT
# Ausgabe weiter auf Konsole anzeigen und zusätzlich in Datei protokollieren
exec > >(tee "$LOG_FILE") 2>&1

source "$BASE_DIR/lib/common.sh"
require_file "$SYSTEMS_FILE"
# shellcheck source=/dev/null
source "$SYSTEMS_FILE"

export_optional_config() {
  local var_name
  for var_name in \
    KEYS_MANAGED_DIR MANAGED_KEY_DIR BACKUP_KEY_FILE \
    RSYSLOG_TARGET_HOST RSYSLOG_TARGET_PORT RSYSLOG_TARGET_PROTOCOL RSYSLOG_REMOTE_FILE \
    SHELL_PACKAGES_DEFAULT SHELL_PACKAGES_D SHELL_PACKAGES_U SHELL_PACKAGES_S SHELL_PACKAGES_B SHELL_PACKAGES_X \
    AUTOFS_PACKAGES_DEFAULT AUTOFS_PACKAGES_D AUTOFS_PACKAGES_U AUTOFS_PACKAGES_S AUTOFS_PACKAGES_B AUTOFS_PACKAGES_X \
    AUTOFS_BASEDIR AUTOFS_MAPS_DIR AUTOFS_FILESYSTEMS
  do
    if declare -p "$var_name" >/dev/null 2>&1; then
      export "$var_name"
    fi
  done
}

export_optional_config
LOCAL_DNS_SUFFIX=$(detect_local_dns_suffix)

usage() {
  cat <<USAGE
Verwendung:
  ./manage.sh <FLAG> <TASK_SCRIPT> [optionen] [-- task-argumente]

Beispiele:
  ./manage.sh UP ./tasks/update_task.sh
  ./manage.sh UP ./tasks/update_task.sh --only app-01.example.net
  ./manage.sh SH ./tasks/shell_task.sh --only 192.0.2.10

Host-Filter:
  --only WERT   Treffer auf IP, DNS-Name oder Name aus .Systems.sh
                kurzer Hostname wird zusätzlich gegen den lokalen DNS-Suffix geprüft
                mehrfach angebbar

Optionen per Environment:
  SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
  SSH_USER=root
  DEBUG=true
  LOG_DIR=./logs
USAGE
}

trim() {
  local value=${1-}
  value=${value##+([[:space:]])}
  value=${value%%+([[:space:]])}
  printf '%s' "$value"
}

detect_local_dns_suffix() {
  local line rest first suffix

  if [[ -r /etc/resolv.conf ]]; then
    while IFS= read -r line; do
      case "$line" in
        search[[:space:]]*|domain[[:space:]]*)
          rest=${line#* }
          first=${rest%%[[:space:]]*}
          first=$(trim "$first")
          if [[ -n $first ]]; then
            printf '%s' "${first,,}"
            return 0
          fi
          ;;
      esac
    done < /etc/resolv.conf
  fi

  suffix=$(hostname -d 2>/dev/null || true)
  suffix=$(trim "$suffix")
  if [[ -n $suffix ]]; then
    printf '%s' "${suffix,,}"
  fi
}

canonical_host_key() {
  local value=${1-}
  local suffix=${2-}

  value=$(trim "$value")
  value=${value,,}
  [[ -n $value ]] || return 1

  if [[ -n $suffix && $value == *."$suffix" ]]; then
    value=${value%."$suffix"}
  fi

  printf '%s' "$value"
}

host_matches_filter() {
  local ip name selector suffix normalized_ip normalized_name normalized_selector candidate
  ip=$(trim "${IP:-}")
  name=$(trim "${Name:-}")
  suffix=${LOCAL_DNS_SUFFIX:-}
  normalized_ip=${ip,,}
  normalized_name=${name,,}

  if (( ${#FILTER_ONLYS[@]} == 0 )); then
    return 0
  fi

  for selector in "${FILTER_ONLYS[@]}"; do
    selector=$(trim "$selector")
    normalized_selector=${selector,,}
    [[ -z $normalized_selector ]] && continue

    [[ $normalized_ip == "$normalized_selector" ]] && return 0
    [[ $normalized_name == "$normalized_selector" ]] && return 0

    candidate=$(canonical_host_key "$normalized_ip" "$suffix" || true)
    [[ -n $candidate && $candidate == "$normalized_selector" ]] && return 0

    candidate=$(canonical_host_key "$normalized_name" "$suffix" || true)
    [[ -n $candidate && $candidate == "$normalized_selector" ]] && return 0

    if [[ $normalized_selector != *.* && -n $suffix ]]; then
      [[ $normalized_ip == "$normalized_selector.$suffix" ]] && return 0
      [[ $normalized_name == "$normalized_selector.$suffix" ]] && return 0
    fi
  done

  return 1
}

init_status_file() {
  cat > "$STATUS_FILE" <<'EOF_STATUS'
# last_run.status
# Format: HOST|IP|FLAG|RESULT|DETAIL
EOF_STATUS
}

append_status() {
  local host=${1:-}
  local ip=${2:-}
  local flag=${3:-}
  local result=${4:-}
  local detail=${5:-}
  printf '%s|%s|%s|%s|%s\n' "$host" "$ip" "$flag" "$result" "$detail" >> "$STATUS_FILE"
}

schedule_queued_reboots() {
  local queue_file=$1
  local reboot_name reboot_ip reboot_jp
  local -a queued_reboots=()

  [[ -s $queue_file ]] || {
    info "Keine Reboots vorgemerkt"
    append_status "-" "-" "$FLAG" "INFO" "Keine Reboots vorgemerkt"
    return 0
  }

  while IFS='|' read -r reboot_name reboot_ip reboot_jp; do
    [[ -n ${reboot_name:-} && -n ${reboot_ip:-} ]] || continue
    queued_reboots+=("${reboot_name} (${reboot_ip})")
  done < "$queue_file"

  warn "${#queued_reboots[@]} System(e) werden jetzt in 5 Minuten neu gestartet:"
  printf '%s\n' "${queued_reboots[@]}"
  info "Starte vorgemerkte Reboots erst nach Abschluss aller Systeme"

  while IFS='|' read -r reboot_name reboot_ip reboot_jp; do
    [[ -n ${reboot_name:-} && -n ${reboot_ip:-} ]] || continue
    Name=$reboot_name
    IP=$reboot_ip
    JP=$reboot_jp
    export Name IP JP

    info "Plane Reboot für ${Name} in 5 Minuten"
    if run_ssh "shutdown -r +5 'Automatischer Neustart nach Wartung'"; then
      info "Reboot für ${Name} erfolgreich vorgemerkt"
      append_status "$Name" "$IP" "$FLAG" "REBOOT_QUEUED" "Neustart in 5 Minuten geplant"
    else
      warn "Reboot für ${Name} konnte nicht vorgemerkt werden"
      append_status "$Name" "$IP" "$FLAG" "REBOOT_FAILED" "Neustart konnte nicht geplant werden"
    fi
  done < "$queue_file"
}

[[ $# -ge 2 ]] || {
  usage >&2
  exit 1
}

FLAG=$1
TASK_SCRIPT=$2
shift 2

FILTER_ONLYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      shift
      [[ $# -gt 0 ]] || { err "--only benötigt mindestens eine IP oder einen DNS-Namen"; exit 1; }
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --|--name|--ip|--id|--only)
            break
            ;;
          *)
            FILTER_ONLYS+=("$1")
            shift
            ;;
        esac
      done
      (( ${#FILTER_ONLYS[@]} > 0 )) || { err "--only benötigt mindestens eine IP oder einen DNS-Namen"; exit 1; }
      ;;
    --)
      shift
      break
      ;;
    --name|--ip|--id)
      err "Nur --only wird unterstützt. Bitte IP oder DNS-Name mit --only angeben."
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

TASK_ARGS=("$@")

[[ -x $TASK_SCRIPT ]] || {
  err "Task-Skript nicht ausführbar: $TASK_SCRIPT"
  exit 1
}

case "$FLAG" in
  UP|KY|RS|SH|AF|BK|FR)
    ;;
  *)
    err "Unbekanntes Flag: $FLAG"
    usage >&2
    exit 1
    ;;
esac

init_status_file
info "Logdatei dieser Ausführung: $LOG_FILE"
info "Statusdatei dieser Ausführung: $STATUS_FILE"
info "Starte Verarbeitung für Flag $FLAG mit Task $TASK_SCRIPT"
if (( ${#FILTER_ONLYS[@]} > 0 )); then
  info "Host-Filter aktiv"
  info "  only=${FILTER_ONLYS[*]}"
fi

processed=0
matched=0
failed=0
skipped=0
filtered_out=0
failed_hosts=()

for LINE in "${HOSTNAMES[@]}"; do
  if [[ $LINE == \#* ]]; then
    continue
  fi

  if [[ $LINE == \!* ]]; then
    header
    continue
  fi

  element
  ((processed+=1))

  if [[ -z ${Name:-} || -z ${IP:-} ]]; then
    warn "Ungültiger Datensatz, überspringe: $LINE"
    ((skipped+=1))
    append_status "-" "-" "$FLAG" "SKIPPED" "Ungültiger Datensatz"
    continue
  fi

  if ! host_matches_filter; then
    ((filtered_out+=1))
    dbg "$Name: nicht im Host-Filter"
    continue
  fi

  current_flag=${!FLAG:-0}
  if [[ $current_flag != "1" ]]; then
    dbg "$Name: $FLAG!=1, übersprungen"
    ((skipped+=1))
    append_status "$Name" "$IP" "$FLAG" "SKIPPED" "Flag $FLAG ist nicht aktiv"
    continue
  fi

  ((matched+=1))
  print_host_banner "$Name ($IP)"

  export Typ ID Name IP BS UP FR BK KY RS SH AF JP REBOOT_QUEUE_FILE STATUS_FILE
  if TASK_NAME="$FLAG" TASK_SCRIPT="$TASK_SCRIPT" BASE_DIR="$BASE_DIR" SYSTEMS_FILE="$SYSTEMS_FILE" bash "$TASK_SCRIPT" "${TASK_ARGS[@]}"; then
    printf '%b%s%b\n' "$TEXT_GREEN" "$Name erfolgreich verarbeitet" "$TEXT_RESET"
    append_status "$Name" "$IP" "$FLAG" "OK" "Task erfolgreich"
  else
    rc=$?
    printf '%b%s%b\n' "$TEXT_RED_B" "$Name fehlgeschlagen (rc=$rc)" "$TEXT_RESET"
    failed_hosts+=("$Name")
    ((failed+=1))
    append_status "$Name" "$IP" "$FLAG" "FAILED" "Task fehlgeschlagen rc=$rc"
  fi
done

if [[ $FLAG == "UP" ]]; then
  schedule_queued_reboots "$REBOOT_QUEUE_FILE"
fi

if (( matched == 0 )); then
  if (( ${#FILTER_ONLYS[@]} > 0 )); then
    warn "Kein System hat auf den angegebenen Filter gepasst"
    append_status "-" "-" "$FLAG" "INFO" "Kein System für gesetzten Host-Filter gefunden"
  else
    warn "Kein System mit aktivem Flag $FLAG gefunden"
    append_status "-" "-" "$FLAG" "INFO" "Kein System mit aktivem Flag gefunden"
  fi
fi

info "Verarbeitet: $processed Datensätze"
info "Passende Ziele: $matched"
info "Durch Host-Filter ausgeschlossen: $filtered_out"
info "Übersprungen: $skipped"
info "Fehlgeschlagen: $failed"

if (( failed > 0 )); then
  failed_hosts_text=$(printf '\n%s' "${failed_hosts[@]}")
  warn "Fehlgeschlagene Systeme: ${failed_hosts_text}"
  exit 1
fi
