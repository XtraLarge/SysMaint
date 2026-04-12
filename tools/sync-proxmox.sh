#!/usr/bin/env bash
# Aktualisiert .Systems.sh mit dem aktuellen Proxmox-Inventar von GVMHP und NAS.
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
DEFAULT_SYSTEMS_FILE="$BASE_DIR/.Systems.sh"
if [[ -r /etc/sysmaint/.Systems.sh ]]; then
  DEFAULT_SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
fi
: "${SYSTEMS_FILE:=$DEFAULT_SYSTEMS_FILE}"
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

declare -A PX_HOST_IP=(
  [GVMHP]="10.10.4.10"
  [NAS]="10.10.5.10"
)
declare -A PX_SECTION=(
  [GVMHP]="VIRTUAL - GVM"
  [NAS]="VIRTUAL - NAS"
)

info() { printf '\033[0;32m[SYNC]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }

get_px_ip() {
  local host_ip=$1 vmid=$2 vmtype=$3
  local config ip

  if [[ $vmtype == "qemu" ]]; then
    config=$(ssh "root@${host_ip}" "qm config ${vmid} 2>/dev/null" 2>/dev/null || true)
  else
    config=$(ssh "root@${host_ip}" "pct config ${vmid} 2>/dev/null" 2>/dev/null || true)
  fi

  ip=$(printf '%s' "$config" | grep -oP '(?<=ip=)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  printf '%s' "${ip:-}"
}

get_existing_vmids() {
  local section_marker=$1
  local in_section=0

  while IFS= read -r line; do
    if [[ $line == *"$section_marker"* ]]; then
      in_section=1
      continue
    fi

    if (( in_section )) && [[ $line =~ ^'# '[A-Z] ]]; then
      break
    fi

    if (( in_section )) && [[ $line =~ ^[VPN][[:space:]] ]]; then
      printf '%s' "$line" | awk -F'#' '{gsub(/[[:space:]]/,"",$2); if ($2 != "") print $2}'
    fi
  done < "$SYSTEMS_FILE"
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
  local section=${PX_SECTION[$host_name]}

  info "Pruefe ${host_name} (${host_ip}) ..."

  local qm_out pct_out
  qm_out=$(ssh "root@${host_ip}" 'qm list 2>/dev/null' 2>/dev/null || true)
  pct_out=$(ssh "root@${host_ip}" 'pct list 2>/dev/null' 2>/dev/null || true)

  local -A existing_ids=()
  while IFS= read -r id; do
    [[ -n $id ]] && existing_ids["$id"]=1
  done < <(get_existing_vmids "$section")

  local added=0

  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*VMID ]] && continue
    [[ -z ${line// /} ]] && continue

    local vmid vmname vm_ip entry
    vmid=$(printf '%s' "$line" | awk '{print $1}')
    vmname=$(printf '%s' "$line" | awk '{print $2}')
    [[ -z $vmid || -z $vmname ]] && continue

    if [[ -z ${existing_ids[$vmid]:-} ]]; then
      vm_ip=$(get_px_ip "$host_ip" "$vmid" "qemu")
      entry=$(printf 'V    #%-3s #%-24s #%-13s #D  #0  #0  #0  #0  #0  #0  #0  #  #  #%s' \
        "$vmid" "$vmname" "${vm_ip:-}" "$host_name")

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
      vm_ip=$(get_px_ip "$host_ip" "$vmid" "lxc")
      entry=$(printf 'V    #%-3s #%-24s #%-13s #D  #0  #0  #0  #0  #0  #0  #0  #  #  #%s' \
        "$vmid" "$vmname" "${vm_ip:-}" "$host_name")

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

for host in GVMHP NAS; do
  sync_host "$host"
done

info "Sync abgeschlossen."
