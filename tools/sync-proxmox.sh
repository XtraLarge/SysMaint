#!/usr/bin/env bash
# Aktualisiert .Systems.sh mit dem aktuellen Proxmox-Inventar aller Hosts mit BS=P.
#
# Verhalten:
# - Neue VMs/Container werden mit allen Flags=0 eingetragen.
# - Bestehende Eintraege werden nicht veraendert.
# - Neue Eintraege enthalten das Feld SG leer, damit das Layout konsistent bleibt.
#
# Verwendung:
#   ./tools/sync-proxmox.sh [--dry-run]
#   SYSTEMS_FILE=/pfad/zur/.Systems.sh ./tools/sync-proxmox.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/lib/common.sh"
DEFAULT_SYSTEMS_FILE="$BASE_DIR/.Systems.sh"
if [[ -r /etc/sysmaint/.Systems.sh ]]; then
  DEFAULT_SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
fi
if [[ -z ${SYSTEMS_FILE:-} || ${SYSTEMS_FILE} == "./.Systems.sh" ]]; then
  SYSTEMS_FILE=$DEFAULT_SYSTEMS_FILE
fi
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

info() { printf '\033[0;32m[SYNC]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }

format_inventory_entry() {
  local typ=$1
  local vmid=$2
  local vmname=$3
  local ip=$4
  local bs=$5
  local host_name=$6

  printf '%-5s#%-4s#%-25s#%-14s#%-4s#0  #0  #0  #0  #0  #0  #0  #%-4s#%-10s#%s' \
    "$typ" "$vmid" "$vmname" "$ip" "$bs" "" "" "$host_name"
}

get_px_ip() {
  local host_name=$1 vmid=$2 vmtype=$3
  local config ip

  if [[ $vmtype == "qemu" ]]; then
    config=$(run_proxmox_ssh "$host_name" "qm config ${vmid} 2>/dev/null" 2>/dev/null || true)
  else
    config=$(run_proxmox_ssh "$host_name" "pct config ${vmid} 2>/dev/null" 2>/dev/null || true)
  fi

  ip=$(printf '%s' "$config" | grep -oP '(?<=ip=)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  printf '%s' "${ip:-}"
}

get_existing_vmids() {
  local host_name=$1
  local line current_section=

  for line in "${HOSTNAMES[@]}"; do
    if [[ $line == '# '* ]] && [[ ! $line =~ ^'# '(Typ|ID|Name|IP|BS|UP|FR|BK|KY|RS|SH|AF|JP|SG|Host|RB)\> ]]; then
      current_section=${line#\# }
      continue
    fi

    [[ $line == \#* || $line == \!* ]] && continue

    LINE=$line
    element

    if [[ ${Host:-} == "$host_name" && -n ${ID:-} ]]; then
      printf '%s\n' "$ID"
    fi
  done
}

load_proxmox_hosts() {
  local line current_section=

  declare -gA PX_HOST_IP=()
  declare -gA PX_HOST_JP=()
  declare -gA PX_SECTION=()

  for line in "${HOSTNAMES[@]}"; do
    if [[ $line == '# '* ]] && [[ ! $line =~ ^'# '(Typ|ID|Name|IP|BS|UP|FR|BK|KY|RS|SH|AF|JP|SG|Host|RB)\> ]]; then
      current_section=${line#\# }
      continue
    fi

    [[ $line == \#* ]] && continue

    if [[ $line == \!* ]]; then
      LINE=$line
      header
      continue
    fi

    LINE=$line
    element

    if [[ ${BS:-} == "P" && -n ${Name:-} && -n ${IP:-} ]]; then
      PX_HOST_IP["$Name"]=$IP
      PX_HOST_JP["$Name"]=${JP:-}
      PX_SECTION["$Name"]="VIRTUAL - ${Name}"
    elif [[ ${Host:-} != "" && -n $current_section && -z ${PX_SECTION[$Host]:-} ]]; then
      PX_SECTION["$Host"]=$current_section
    fi
  done
}

run_proxmox_ssh() {
  local host_name=$1
  shift

  IP=${PX_HOST_IP[$host_name]}
  JP=${PX_HOST_JP[$host_name]-}
  Name=$host_name
  run_ssh "$@"
}

insert_before_section_end() {
  local section_marker=$1
  local new_line=$2
  local tmpfile
  tmpfile=$(mktemp)

  awk -v marker="$section_marker" -v newline="$new_line" '
    BEGIN { in_section=0; inserted=0 }
    {
      if (!in_section && index($0, marker) > 0) {
        in_section=1
        print
        next
      }

      if (in_section && !inserted) {
        if ($0 ~ /^#$/ || ($0 ~ /^# [A-Z]/ && index($0, marker) == 0) || $0 ~ /^SYSTEMS_EOF/) {
          print newline
          inserted=1
        }
      }

      print
    }
  ' "$SYSTEMS_FILE" > "$tmpfile"

  mv "$tmpfile" "$SYSTEMS_FILE"
}

sync_host() {
  local host_name=$1
  local host_ip=${PX_HOST_IP[$host_name]}
  local host_jp=${PX_HOST_JP[$host_name]-}
  local section=${PX_SECTION[$host_name]}

  if [[ -n $host_jp ]]; then
    info "Pruefe ${host_name} (${host_ip}) via Jump-Host ${host_jp} ..."
  else
    info "Pruefe ${host_name} (${host_ip}) ..."
  fi

  local qm_out pct_out
  qm_out=$(run_proxmox_ssh "$host_name" 'qm list 2>/dev/null' 2>/dev/null || true)
  pct_out=$(run_proxmox_ssh "$host_name" 'pct list 2>/dev/null' 2>/dev/null || true)

  local -A existing_ids=()
  while IFS= read -r id; do
    [[ -n $id ]] && existing_ids["$id"]=1
  done < <(get_existing_vmids "$host_name")

  local added=0

  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*VMID ]] && continue
    [[ -z ${line// /} ]] && continue

    local vmid vmname vm_ip entry
    vmid=$(printf '%s' "$line" | awk '{print $1}')
    vmname=$(printf '%s' "$line" | awk '{print $2}')
    [[ -z $vmid || -z $vmname ]] && continue

    if [[ -z ${existing_ids[$vmid]:-} ]]; then
      vm_ip=$(get_px_ip "$host_name" "$vmid" "qemu")
      entry=$(format_inventory_entry "V" "$vmid" "$vmname" "${vm_ip:-}" "D" "$host_name")

      info "  NEU (VM)  VMID=${vmid} Name=${vmname} IP=${vm_ip:-leer}"
      if (( DRY_RUN == 0 )); then
        insert_before_section_end "$section" "$entry"
        existing_ids["$vmid"]=1
      fi
      (( added++ )) || true
    fi
  done <<< "$qm_out"

  while IFS= read -r line; do
    [[ $line =~ ^VMID ]] && continue
    [[ -z ${line// /} ]] && continue

    local vmid vmname vm_ip entry
    vmid=$(printf '%s' "$line" | awk '{print $1}')
    vmname=$(printf '%s' "$line" | awk '{print $NF}')
    [[ -z $vmid || -z $vmname || $vmid == "$vmname" ]] && continue

    if [[ -z ${existing_ids[$vmid]:-} ]]; then
      vm_ip=$(get_px_ip "$host_name" "$vmid" "lxc")
      entry=$(format_inventory_entry "V" "$vmid" "$vmname" "${vm_ip:-}" "D" "$host_name")

      info "  NEU (LXC) VMID=${vmid} Name=${vmname} IP=${vm_ip:-leer}"
      if (( DRY_RUN == 0 )); then
        insert_before_section_end "$section" "$entry"
        existing_ids["$vmid"]=1
      fi
      (( added++ )) || true
    fi
  done <<< "$pct_out"

  if (( added == 0 )); then
    info "  Keine neuen Eintraege fuer ${host_name}."
  else
    info "  ${added} neue Eintraege fuer ${host_name} hinzugefuegt."
  fi
}

if (( DRY_RUN == 0 )); then
  cp "$SYSTEMS_FILE" "${SYSTEMS_FILE}.bak"
  info "Backup: ${SYSTEMS_FILE}.bak"
fi

(( DRY_RUN )) && info "DRY-RUN Modus -- keine Aenderungen werden geschrieben"

source "$SYSTEMS_FILE"
systems_init
load_proxmox_hosts

if (( ${#PX_HOST_IP[@]} == 0 )); then
  warn "Keine Proxmox-Hosts mit BS=P in $SYSTEMS_FILE gefunden."
fi

for host in "${!PX_HOST_IP[@]}"; do
  sync_host "$host"
done

info "Sync abgeschlossen."
