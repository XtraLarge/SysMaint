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
    DEFAULT_JOBS \
    DEFAULT_REBOOT_DELAY LOCAL_REBOOT_DELAY \
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

usage() {
  cat <<USAGE
Verwendung:
  ./manage.sh <FLAG> <TASK_SCRIPT> [optionen] [-- task-argumente]

Beispiele:
  ./manage.sh UP ./tasks/update_task.sh
  ./manage.sh UP ./tasks/update_task.sh --jobs 6
  ./manage.sh UP ./tasks/update_task.sh --only app-01.example.net
  ./manage.sh SH ./tasks/shell_task.sh --only 192.0.2.10

Host-Filter:
  --only WERT   exakter Treffer auf das IP-/DNS-Feld aus .Systems.sh
                mehrfach angebbar
  --jobs N      maximale Zahl gleichzeitiger Host-Jobs, Standard aus DEFAULT_JOBS oder 1

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

LOCAL_DNS_SUFFIX=$(detect_local_dns_suffix)

register_inventory_ref() {
  local ref=${1-}
  local key=${2-}
  local normalized canonical suffix

  ref=$(trim "$ref")
  [[ -n $ref && -n $key ]] || return 0

  normalized=${ref,,}
  INVENTORY_REF_TO_KEY["$normalized"]=$key

  suffix=${LOCAL_DNS_SUFFIX:-}
  canonical=$(canonical_host_key "$normalized" "$suffix" || true)
  if [[ -n $canonical ]]; then
    INVENTORY_REF_TO_KEY["$canonical"]=$key
    if [[ -n $suffix && $canonical != *.* ]]; then
      INVENTORY_REF_TO_KEY["$canonical.$suffix"]=$key
    fi
  fi
}

build_inventory_maps() {
  local saved_line=${LINE-}
  local saved_typ=${Typ-}
  local saved_id=${ID-}
  local saved_name=${Name-}
  local saved_ip=${IP-}
  local saved_bs=${BS-}
  local saved_up=${UP-}
  local saved_fr=${FR-}
  local saved_bk=${BK-}
  local saved_ky=${KY-}
  local saved_rs=${RS-}
  local saved_sh=${SH-}
  local saved_af=${AF-}
  local saved_jp=${JP-}
  local saved_sg=${SG-}
  local saved_host=${Host-}
  local saved_rb=${RB-}
  local line key name ip

  declare -gA INVENTORY_REF_TO_KEY=()
  declare -gA INVENTORY_NAME_BY_KEY=()
  declare -gA INVENTORY_IP_BY_KEY=()
  declare -gA INVENTORY_JP_BY_KEY=()
  declare -gA INVENTORY_HOST_BY_KEY=()
  declare -gA INVENTORY_RB_BY_KEY=()

  for line in "${HOSTNAMES[@]}"; do
    [[ $line == \#* ]] && continue
    if [[ $line == \!* ]]; then
      LINE=$line
      header
      continue
    fi

    LINE=$line
    element

    name=$(trim "${Name:-}")
    ip=$(trim "${IP:-}")
    [[ -n $name || -n $ip ]] || continue

    key=$(canonical_host_key "${name:-$ip}" "${LOCAL_DNS_SUFFIX:-}" || true)
    [[ -n $key ]] || key=${ip,,}

    INVENTORY_NAME_BY_KEY["$key"]=$name
    INVENTORY_IP_BY_KEY["$key"]=$ip
    INVENTORY_JP_BY_KEY["$key"]=${JP:-}
    INVENTORY_HOST_BY_KEY["$key"]=${Host:-}
    INVENTORY_RB_BY_KEY["$key"]=${RB:-}

    register_inventory_ref "$name" "$key"
    register_inventory_ref "$ip" "$key"
  done

  LINE=$saved_line
  Typ=$saved_typ
  ID=$saved_id
  Name=$saved_name
  IP=$saved_ip
  BS=$saved_bs
  UP=$saved_up
  FR=$saved_fr
  BK=$saved_bk
  KY=$saved_ky
  RS=$saved_rs
  SH=$saved_sh
  AF=$saved_af
  JP=$saved_jp
  SG=$saved_sg
  Host=$saved_host
  RB=$saved_rb
}

resolve_inventory_ref() {
  local ref=${1-}
  local normalized

  ref=$(trim "$ref")
  [[ -n $ref ]] || return 1
  normalized=${ref,,}
  [[ -n ${INVENTORY_REF_TO_KEY[$normalized]+x} ]] || return 1
  printf '%s' "${INVENTORY_REF_TO_KEY[$normalized]}"
}

host_matches_filter() {
  local ip selector normalized_ip normalized_selector
  ip=$(trim "${IP:-}")
  normalized_ip=${ip,,}

  if (( ${#FILTER_ONLYS[@]} == 0 )); then
    return 0
  fi

  for selector in "${FILTER_ONLYS[@]}"; do
    selector=$(trim "$selector")
    normalized_selector=${selector,,}
    [[ -z $normalized_selector ]] && continue

    [[ $normalized_ip == "$normalized_selector" ]] && return 0
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

sanitize_job_name() {
  local value=${1:-host}
  value=${value//[^[:alnum:]._-]/_}
  printf '%s' "$value"
}

run_task_for_current_host() {
  export Typ ID Name IP BS UP FR BK KY RS SH AF JP SG Host RB REBOOT_QUEUE_FILE STATUS_FILE AUTOFS_RELOAD_MARKER
  TASK_NAME="$FLAG" TASK_SCRIPT="$TASK_SCRIPT" BASE_DIR="$BASE_DIR" SYSTEMS_FILE="$SYSTEMS_FILE" bash "$TASK_SCRIPT" "${TASK_ARGS[@]}"
}

reload_autofs_after_run_if_needed() {
  [[ -n ${AUTOFS_RELOAD_MARKER:-} && -s $AUTOFS_RELOAD_MARKER ]] || {
    info "Kein AutoFS-Reload nötig"
    return 0
  }

  if command -v systemctl >/dev/null 2>&1; then
    info "Lade AutoFS-Service nach Abschluss des Laufs neu"
    systemctl enable --now autofs >/dev/null 2>&1 || true
    systemctl reload autofs >/dev/null 2>&1 || systemctl restart autofs
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    info "Starte AutoFS-Service nach Abschluss des Laufs neu"
    service autofs restart
    return 0
  fi

  warn "Kein unterstützter Service-Manager für AutoFS gefunden"
}

build_local_execution_scope() {
  local ref key parent_ref parent_key
  local suffix=${LOCAL_DNS_SUFFIX:-}
  local -a local_refs=()
  declare -gA LOCAL_EXECUTION_KEYS=()

  local_refs+=("$(hostname 2>/dev/null || true)")
  local_refs+=("$(hostname -s 2>/dev/null || true)")
  local_refs+=("$(hostname -f 2>/dev/null || true)")

  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    local_refs+=("$ref")
  done < <(hostname -I 2>/dev/null | tr ' ' '\n')

  for ref in "${local_refs[@]}"; do
    ref=$(trim "$ref")
    [[ -n $ref ]] || continue
    key=$(resolve_inventory_ref "$ref" || true)
    [[ -n $key ]] || key=$(canonical_host_key "$ref" "$suffix" || true)
    [[ -n $key ]] || continue
    LOCAL_EXECUTION_KEYS["$key"]=1
  done

  for key in "${!LOCAL_EXECUTION_KEYS[@]}"; do
    parent_key=$key
    while :; do
      parent_ref=${INVENTORY_HOST_BY_KEY[$parent_key]-}
      [[ -n $parent_ref ]] || break
      parent_key=$(resolve_inventory_ref "$parent_ref" || true)
      [[ -n $parent_key ]] || break
      [[ -n ${LOCAL_EXECUTION_KEYS[$parent_key]+x} ]] && break
      LOCAL_EXECUTION_KEYS["$parent_key"]=1
    done
  done
}

reboot_delay_for_key() {
  local key=${1-}
  local delay=${INVENTORY_RB_BY_KEY[$key]-}

  if [[ -n $delay ]]; then
    printf '%s' "$delay"
    return 0
  fi

  if [[ -n ${LOCAL_EXECUTION_KEYS[$key]+x} ]]; then
    printf '%s' "${LOCAL_REBOOT_DELAY:-5}"
    return 0
  fi

  printf '%s' "${DEFAULT_REBOOT_DELAY:-1}"
}

start_parallel_job() {
  local index=$1
  local job_name=$2
  local job_ip=$3
  local job_bs=$4
  local job_typ=$5
  local job_id=$6
  local job_up=$7
  local job_fr=$8
  local job_bk=$9
  local job_ky=${10}
  local job_rs=${11}
  local job_sh=${12}
  local job_af=${13}
  local job_jp=${14}
  local job_sg=${15}
  local job_host=${16}
  local job_rb=${17}
  local job_slug
  local job_log
  local job_reboot
  local job_result

  job_slug=$(sanitize_job_name "${job_name}_${job_ip}")
  job_log="${JOB_RUN_DIR}/${job_slug}.log"
  job_reboot="${JOB_RUN_DIR}/${job_slug}.reboots"
  job_result="${JOB_RUN_DIR}/${job_slug}.result"

  print_host_banner "$job_name ($job_ip)"
  info "Starte Job ${index} für ${job_name}, Log: ${job_log}"

  (
    set +e
    Name=$job_name
    IP=$job_ip
    BS=$job_bs
    Typ=$job_typ
    ID=$job_id
    UP=$job_up
    FR=$job_fr
    BK=$job_bk
    KY=$job_ky
    RS=$job_rs
    SH=$job_sh
    AF=$job_af
    JP=$job_jp
    SG=$job_sg
    Host=$job_host
    RB=$job_rb
    REBOOT_QUEUE_FILE=$job_reboot
    STATUS_FILE=/dev/null

    if run_task_for_current_host >"$job_log" 2>&1; then
      printf 'OK\n' > "$job_result"
    else
      rc=$?
      printf 'FAILED|%s\n' "$rc" > "$job_result"
    fi
  ) &

  JOB_PIDS[$index]=$!
  JOB_NAMES[$index]=$job_name
  JOB_IPS[$index]=$job_ip
  JOB_LOGS[$index]=$job_log
  JOB_REBOOTS[$index]=$job_reboot
  JOB_RESULTS[$index]=$job_result
}

finish_parallel_job() {
  local index=$1
  local pid=${JOB_PIDS[$index]-}
  local job_name=${JOB_NAMES[$index]-}
  local job_ip=${JOB_IPS[$index]-}
  local job_log=${JOB_LOGS[$index]-}
  local job_reboot=${JOB_REBOOTS[$index]-}
  local job_result=${JOB_RESULTS[$index]-}
  local result rc

  [[ -n ${pid:-} ]] || return 0

  wait "$pid" || true
  result=$(<"$job_result")

  if [[ -s $job_log ]]; then
    print_host_banner "$job_name ($job_ip) - Ausgabe"
    while IFS= read -r line || [[ -n $line ]]; do
      printf '[%s] %s\n' "$job_name" "$line"
    done < "$job_log"
  fi

  if [[ $result == OK* ]]; then
    printf '%b%s%b\n' "$TEXT_GREEN" "$job_name erfolgreich verarbeitet" "$TEXT_RESET"
    append_status "$job_name" "$job_ip" "$FLAG" "OK" "Task erfolgreich"
  else
    rc=${result#FAILED|}
    printf '%b%s%b\n' "$TEXT_RED_B" "$job_name fehlgeschlagen (rc=$rc)" "$TEXT_RESET"
    warn "Job-Log für ${job_name}: ${job_log}"
    failed_hosts+=("$job_name")
    ((failed+=1))
    append_status "$job_name" "$job_ip" "$FLAG" "FAILED" "Task fehlgeschlagen rc=$rc"
  fi

  if [[ -s $job_reboot ]]; then
    cat "$job_reboot" >> "$REBOOT_QUEUE_FILE"
  fi

  unset "JOB_PIDS[$index]" "JOB_NAMES[$index]" "JOB_IPS[$index]" "JOB_LOGS[$index]" "JOB_REBOOTS[$index]" "JOB_RESULTS[$index]"
  running_jobs=$((running_jobs - 1))
}

wait_for_parallel_slot() {
  local idx pid
  while (( running_jobs >= JOBS )); do
    for idx in "${!JOB_PIDS[@]}"; do
      pid=${JOB_PIDS[$idx]-}
      [[ -n ${pid:-} ]] || continue
      if ! kill -0 "$pid" 2>/dev/null; then
        finish_parallel_job "$idx"
        return 0
      fi
    done
    sleep 0.1
  done
}

wait_for_all_parallel_jobs() {
  local idx
  for idx in "${!JOB_PIDS[@]}"; do
    finish_parallel_job "$idx"
  done
}

schedule_queued_reboots() {
  local queue_file=$1
  local reboot_name reboot_ip reboot_jp reboot_key target_key current parent_ref parent_key reboot_delay
  local display_name display_ip
  local -a requested_order=()
  local -a planned_order=()
  local -a covered_reboots=()
  local -A requested_set=()
  local -A requested_name=()
  local -A requested_ip=()
  local -A requested_jp=()
  local -A planned_set=()
  local -A seen_chain=()

  [[ -s $queue_file ]] || {
    info "Keine Reboots vorgemerkt"
    append_status "-" "-" "$FLAG" "INFO" "Keine Reboots vorgemerkt"
    return 0
  }

  build_inventory_maps
  build_local_execution_scope

  while IFS='|' read -r reboot_name reboot_ip reboot_jp; do
    [[ -n ${reboot_name:-} && -n ${reboot_ip:-} ]] || continue
    reboot_key=$(resolve_inventory_ref "$reboot_name" || resolve_inventory_ref "$reboot_ip" || true)
    if [[ -z $reboot_key ]]; then
      reboot_key=$(canonical_host_key "${reboot_name:-$reboot_ip}" "${LOCAL_DNS_SUFFIX:-}" || true)
      [[ -n $reboot_key ]] || reboot_key=${reboot_ip,,}
    fi

    if [[ -z ${requested_set[$reboot_key]+x} ]]; then
      requested_order+=("$reboot_key")
      requested_set["$reboot_key"]=1
      requested_name["$reboot_key"]=$reboot_name
      requested_ip["$reboot_key"]=$reboot_ip
      requested_jp["$reboot_key"]=$reboot_jp
    fi
  done < "$queue_file"

  for reboot_key in "${requested_order[@]}"; do
    target_key=$reboot_key
    unset seen_chain
    declare -A seen_chain=()
    seen_chain["$target_key"]=1

    while :; do
      parent_ref=${INVENTORY_HOST_BY_KEY[$target_key]-}
      [[ -n $parent_ref ]] || break
      parent_key=$(resolve_inventory_ref "$parent_ref" || true)
      [[ -n $parent_key ]] || break
      [[ -n ${seen_chain[$parent_key]+x} ]] && break
      seen_chain["$parent_key"]=1
      [[ -n ${requested_set[$parent_key]+x} ]] || break
      target_key=$parent_key
    done

    if [[ $target_key != "$reboot_key" ]]; then
      covered_reboots+=("${requested_name[$reboot_key]} (${requested_ip[$reboot_key]}) -> ${requested_name[$target_key]} (${requested_ip[$target_key]})")
      append_status "${requested_name[$reboot_key]}" "${requested_ip[$reboot_key]}" "$FLAG" "REBOOT_COVERED" "Durch Host-Reboot von ${requested_name[$target_key]} abgedeckt"
      continue
    fi

    if [[ -z ${planned_set[$target_key]+x} ]]; then
      planned_order+=("$target_key")
      planned_set["$target_key"]=1
    fi
  done

  warn "${#planned_order[@]} System(e) werden jetzt zum Reboot eingeplant:"
  for current in "${planned_order[@]}"; do
    display_name=${requested_name[$current]}
    display_ip=${requested_ip[$current]}
    reboot_delay=$(reboot_delay_for_key "$current")
    printf '%s (%s) in %s Minute(n)\n' "$display_name" "$display_ip" "$reboot_delay"
  done
  if (( ${#covered_reboots[@]} > 0 )); then
    info "${#covered_reboots[@]} System(e) werden nicht separat rebootet, weil ihr Host ebenfalls rebootet:"
    printf '%s\n' "${covered_reboots[@]}"
  fi
  info "Starte vorgemerkte Reboots erst nach Abschluss aller Systeme"

  for current in "${planned_order[@]}"; do
    reboot_name=${requested_name[$current]}
    reboot_ip=${requested_ip[$current]}
    reboot_jp=${requested_jp[$current]}
    reboot_delay=$(reboot_delay_for_key "$current")
    Name=$reboot_name
    IP=$reboot_ip
    JP=$reboot_jp
    export Name IP JP

    info "Plane Reboot für ${Name} in ${reboot_delay} Minute(n)"
    if run_ssh "shutdown -r +${reboot_delay} 'Automatischer Neustart nach Wartung'" </dev/null; then
      info "Reboot für ${Name} erfolgreich vorgemerkt"
      append_status "$Name" "$IP" "$FLAG" "REBOOT_QUEUED" "Neustart in ${reboot_delay} Minuten geplant"
    else
      warn "Reboot für ${Name} konnte nicht vorgemerkt werden"
      append_status "$Name" "$IP" "$FLAG" "REBOOT_FAILED" "Neustart konnte nicht geplant werden"
    fi
  done
}

[[ $# -ge 2 ]] || {
  usage >&2
  exit 1
}

FLAG=$1
TASK_SCRIPT=$2
shift 2

FILTER_ONLYS=()
JOBS=${DEFAULT_JOBS:-1}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      shift
      [[ $# -gt 0 ]] || { err "--jobs benötigt eine Zahl"; exit 1; }
      [[ $1 =~ ^[1-9][0-9]*$ ]] || { err "--jobs benötigt eine ganze Zahl größer 0"; exit 1; }
      JOBS=$1
      shift
      ;;
    --only)
      shift
      [[ $# -gt 0 ]] || { err "--only benötigt mindestens eine exakte IP oder einen exakten DNS-Namen aus .Systems.sh"; exit 1; }
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --|--name|--ip|--id|--only|--jobs)
            break
            ;;
          *)
            FILTER_ONLYS+=("$1")
            shift
            ;;
        esac
      done
      (( ${#FILTER_ONLYS[@]} > 0 )) || { err "--only benötigt mindestens eine exakte IP oder einen exakten DNS-Namen aus .Systems.sh"; exit 1; }
      ;;
    only)
      err "Ungültiger Aufruf: 'only' wird nicht unterstützt. Verwende --only <IP-oder-DNS-aus-.Systems.sh>."
      exit 1
      ;;
    --)
      shift
      break
      ;;
    --name|--ip|--id)
      err "Nur --only wird unterstützt. Bitte exakte IP oder exakten DNS-Namen aus .Systems.sh mit --only angeben."
      exit 1
      ;;
    *)
      err "Unbekanntes Argument vor --: $1"
      usage >&2
      exit 1
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

if [[ $FLAG == "AF" && $JOBS != "1" ]]; then
  warn "AutoFS arbeitet lokal auf dem Manage-Host. Parallele Jobs werden dafür auf 1 gesetzt."
  JOBS=1
fi

init_status_file
info "Logdatei dieser Ausführung: $LOG_FILE"
info "Statusdatei dieser Ausführung: $STATUS_FILE"
info "Starte Verarbeitung für Flag $FLAG mit Task $TASK_SCRIPT"
info "Parallele Jobs: $JOBS"
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
running_jobs=0
declare -a JOB_PIDS=()
declare -a JOB_NAMES=()
declare -a JOB_IPS=()
declare -a JOB_LOGS=()
declare -a JOB_REBOOTS=()
declare -a JOB_RESULTS=()
JOB_RUN_DIR="$LOG_DIR/last_jobs"
rm -rf "$JOB_RUN_DIR"
mkdir -p "$JOB_RUN_DIR"
AUTOFS_RELOAD_MARKER=$(mktemp)
trap 'rm -f "$REBOOT_QUEUE_FILE"' EXIT
info "Job-Logs dieser Ausführung: $JOB_RUN_DIR"

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

  if (( JOBS > 1 )); then
    wait_for_parallel_slot
    start_parallel_job "$matched" "$Name" "$IP" "$BS" "$Typ" "$ID" "$UP" "$FR" "$BK" "$KY" "$RS" "$SH" "$AF" "$JP" "${SG:-}" "${Host:-}" "${RB:-}"
    ((running_jobs+=1))
  else
    print_host_banner "$Name ($IP)"
    if run_task_for_current_host; then
      printf '%b%s%b\n' "$TEXT_GREEN" "$Name erfolgreich verarbeitet" "$TEXT_RESET"
      append_status "$Name" "$IP" "$FLAG" "OK" "Task erfolgreich"
    else
      rc=$?
      printf '%b%s%b\n' "$TEXT_RED_B" "$Name fehlgeschlagen (rc=$rc)" "$TEXT_RESET"
      failed_hosts+=("$Name")
      ((failed+=1))
      append_status "$Name" "$IP" "$FLAG" "FAILED" "Task fehlgeschlagen rc=$rc"
    fi
  fi
done

if (( JOBS > 1 )); then
  wait_for_all_parallel_jobs
fi

if [[ $FLAG == "UP" ]]; then
  schedule_queued_reboots "$REBOOT_QUEUE_FILE"
elif [[ $FLAG == "AF" ]]; then
  reload_autofs_after_run_if_needed
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
