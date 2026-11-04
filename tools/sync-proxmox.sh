#!/usr/bin/env bash
# Gleicht .Systems.sh mit dem Live-Inventar aller Proxmox-Hosts (BS=P) ab.
#
# Verhalten:
# - Neue Gaeste werden analysiert (Typ, OS, IP, SSH-Erreichbarkeit) und mit
#   passenden Flags eingetragen: per SSH erreichbare Debian/Ubuntu-Systeme
#   bekommen den Flotten-Standard (SYNC_DEFAULT_FLAGS), alle anderen nur AF=1.
# - Gaeste, die auf einen anderen Proxmox-Host migriert wurden, bekommen das
#   Host-Feld angepasst.
# - Verschwundene Gaeste sowie Namens- und IP-Abweichungen werden nur gemeldet,
#   nie automatisch entfernt.
# - Gestoppte Gaeste werden als STOPPED gemeldet (Auswertung im Wochenlauf).
# - Ist das Verzeichnis der Inventardatei ein Git-Repository, wird jede
#   Aenderung dort committet; sonst wird wie bisher eine .bak-Kopie angelegt.
#
# Verwendung:
#   ./tools/sync-proxmox.sh [--dry-run] [--report DATEI]
#
# Report-Format (eine Zeile je Befund):
#   ART|PROXMOX-HOST|TYP|VMID|NAME|IP|DETAIL
#   ART: NEW, MOVED, GONE, NAME, IP, STOPPED, NOSSH, PXERROR
#
# Exit-Code: 0 = keine offenen Abweichungen
#            1 = Abweichungen, die eine Pruefung brauchen (GONE, NAME, IP, NOSSH)
#            2 = mindestens ein Proxmox-Host war nicht abfragbar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

if [[ -r /etc/sysmaint/config.sh ]]; then
  # shellcheck source=/dev/null
  source /etc/sysmaint/config.sh
elif [[ -r $BASE_DIR/config.sh ]]; then
  # shellcheck source=/dev/null
  source "$BASE_DIR/config.sh"
fi

DEFAULT_SYSTEMS_FILE="$BASE_DIR/.Systems.sh"
if [[ -r /etc/sysmaint/.Systems.sh ]]; then
  DEFAULT_SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
fi
if [[ -z ${SYSTEMS_FILE:-} || ${SYSTEMS_FILE} == "./.Systems.sh" ]]; then
  SYSTEMS_FILE=$DEFAULT_SYSTEMS_FILE
fi

# Flags fuer neue, erreichbare Debian-Systeme: UP FR BK KY RS SH AF
: "${SYNC_DEFAULT_FLAGS:=1 1 1 1 1 1 1}"
# Flags fuer alle anderen neuen Systeme (nicht erreichbar, gestoppt, kein Debian)
: "${SYNC_FALLBACK_FLAGS:=0 0 0 0 0 0 1}"
# Kurzer Deckel fuer Proben auf neue Gaeste
: "${SYNC_PROBE_TIMEOUT:=20}"

DRY_RUN=0
REPORT_FILE=

while (( $# > 0 )); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --report)
      shift
      [[ $# -gt 0 ]] || { err "--report benoetigt einen Dateinamen"; exit 2; }
      REPORT_FILE=$1
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) err "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

say()  { printf '[SYNC] %s\n' "$*"; }
note() { printf '[SYNC] %s\n' "$*" >&2; }

REPORT_LINES=()
report() {
  local line
  line=$(IFS='|'; printf '%s' "$*")
  REPORT_LINES+=("$line")
  say "  $1: $line"
}

# --------------------------------------------------------------------------
# Inventar einlesen
# --------------------------------------------------------------------------
require_file "$SYSTEMS_FILE"
# shellcheck source=/dev/null
source "$SYSTEMS_FILE"
IFS=$' \t\n'
systems_init

HOST_FIELD_INDEX=-1
for i in "${!HEAD[@]}"; do
  [[ ${HEAD[$i]} == Host ]] && HOST_FIELD_INDEX=$i
done
(( HOST_FIELD_INDEX >= 0 )) || { err "Feld Host fehlt in der Kopfzeile von $SYSTEMS_FILE"; exit 2; }

declare -A PX_IP=() PX_JP=()
declare -A INV_ENTRY=()      # "<px>|<vmid>" -> "<name>|<ip>"
declare -A INV_BY_ID=()      # "<vmid>|<name lowercase>" -> "<px>"

for line in "${HOSTNAMES[@]}"; do
  [[ $line == \#* || $line == \!* || -z ${line//[[:space:]]/} ]] && continue
  LINE=$line
  element
  if [[ ${BS:-} == P && -n ${Name:-} ]]; then
    PX_IP["$Name"]=$IP
    PX_JP["$Name"]=${JP:-}
  fi
  if [[ -n ${Host:-} && -n ${ID:-} ]]; then
    INV_ENTRY["$Host|$ID"]="$Name|$IP"
    INV_BY_ID["$ID|${Name,,}"]=$Host
  fi
done

if (( ${#PX_IP[@]} == 0 )); then
  note "Keine Proxmox-Hosts mit BS=P in $SYSTEMS_FILE gefunden."
  exit 0
fi

# --------------------------------------------------------------------------
# Live-Inventar je Proxmox-Host holen (ein SSH-Aufruf pro Host)
# Ausgabe je Gast: typ|vmid|name|status|ip1,ip2,...|ostype
# --------------------------------------------------------------------------
REMOTE_LIST=$(cat <<'EOF_REMOTE'
for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  c=$(pct config "$id" 2>/dev/null)
  st=$(pct status "$id" 2>/dev/null | awk '{print $2}')
  name=$(printf '%s\n' "$c" | awk '/^hostname:/{print $2; exit}')
  ips=$(printf '%s\n' "$c" | grep -o 'ip=[0-9.]*' | cut -d= -f2 | paste -sd, -)
  os=$(printf '%s\n' "$c" | awk '/^ostype:/{print $2; exit}')
  printf 'lxc|%s|%s|%s|%s|%s\n' "$id" "$name" "$st" "$ips" "$os"
done
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  c=$(qm config "$id" 2>/dev/null)
  st=$(qm status "$id" 2>/dev/null | awk '{print $2}')
  name=$(printf '%s\n' "$c" | awk '/^name:/{print $2; exit}')
  os=$(printf '%s\n' "$c" | awk '/^ostype:/{print $2; exit}')
  ips=$(printf '%s\n' "$c" | grep -o 'ip=[0-9.]*' | cut -d= -f2 | paste -sd, -)
  if [ -z "$ips" ] && [ "$st" = running ]; then
    ips=$(timeout 5 qm guest cmd "$id" network-get-interfaces 2>/dev/null \
      | grep -o '"ip-address" : "[0-9.]*"' | cut -d'"' -f4 \
      | grep -v -E '^(127\.|169\.254\.)' | paste -sd, -)
  fi
  printf 'qemu|%s|%s|%s|%s|%s\n' "$id" "$name" "$st" "$ips" "$os"
done
EOF_REMOTE
)

declare -A LIVE=()           # "<px>|<vmid>" -> "typ|name|status|ips|ostype"
declare -A LIVE_BY_ID=()     # "<vmid>|<name lowercase>" -> "<px>"
declare -A PX_OK=()
PX_FAILED=0

for px in $(printf '%s\n' "${!PX_IP[@]}" | sort); do
  if [[ -n ${PX_JP[$px]} ]]; then
    say "Pruefe ${px} (${PX_IP[$px]}) via Jump-Host ${PX_JP[$px]} ..."
  else
    say "Pruefe ${px} (${PX_IP[$px]}) ..."
  fi
  Name=$px IP=${PX_IP[$px]} JP=${PX_JP[$px]}
  if ! out=$(run_ssh_bash "$REMOTE_LIST" 2>/dev/null); then
    report PXERROR "$px" - - - "${PX_IP[$px]}" "Proxmox-Host nicht abfragbar"
    PX_FAILED=1
    continue
  fi
  PX_OK["$px"]=1
  while IFS='|' read -r typ vmid vname st ips os; do
    [[ -n $vmid ]] || continue
    LIVE["$px|$vmid"]="$typ|$vname|$st|$ips|$os"
    LIVE_BY_ID["$vmid|${vname,,}"]=$px
  done <<< "$out"
done

# --------------------------------------------------------------------------
# Hilfsfunktionen fuer Analyse und Dateiaenderungen
# --------------------------------------------------------------------------
first_ip() {
  local ips=$1
  printf '%s' "${ips%%,*}"
}

ip_in_list() {
  local ip=$1 ips=$2
  [[ ",$ips," == *",$ip,"* ]]
}

# Ermittelt BS und Flags fuer einen neuen Gast. Ausgabe: "<BS>|<flags>|<hinweis>"
analyse_guest() {
  local px=$1 typ=$2 st=$3 ip=$4 os=$5
  local bs=X hint="" osid=""

  case $os in
    win*|wxp|w2k*|wvista) bs=W ;;
  esac

  if [[ $bs != W && $st == running && -n $ip ]]; then
    osid=$(Name=$ip IP=$ip JP=${PX_JP[$px]} SSH_CMD_TIMEOUT=$SYNC_PROBE_TIMEOUT \
      run_ssh '. /etc/os-release 2>/dev/null && printf "%s" "$ID"' 2>/dev/null || true)
    if [[ -z $osid ]]; then
      hint="kein SSH-Zugang mit dem Management-Key"
    fi
  elif [[ $st != running ]]; then
    hint="gestoppt, nicht analysierbar"
  elif [[ -z $ip ]]; then
    hint="keine IP ermittelbar"
  fi

  case $osid in
    debian|ubuntu) bs=D ;;
    sles|opensuse*) bs=S ;;
    univention) bs=U ;;
  esac
  if [[ -z $osid && $typ == lxc && $bs == X ]]; then
    case $os in debian|ubuntu) bs=D ;; esac
  fi

  if [[ -n $osid && $bs =~ ^(D|U|S)$ ]]; then
    printf '%s|%s|%s' "$bs" "$SYNC_DEFAULT_FLAGS" "erreichbar ($osid), Standard-Flags"
  else
    printf '%s|%s|%s' "$bs" "$SYNC_FALLBACK_FLAGS" "${hint:-kein unterstuetztes OS}"
  fi
}

format_entry() {
  local vmid=$1 vname=$2 ip=$3 bs=$4 flags=$5 px=$6
  local -a f
  read -r -a f <<< "$flags"
  printf '%-5s#%-4s#%-25s#%-14s#%-4s#%-3s#%-3s#%-3s#%-3s#%-3s#%-3s#%-3s#%-4s#%-10s#%-6s#' \
    V "$vmid" "$vname" "$ip" "$bs" "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "${f[6]}" "" "" "$px"
}

# Fuegt eine Zeile hinter dem letzten Eintrag mit Host=<px> ein; gibt es keinen,
# vor SYSTEMS_EOF in einem neuen Abschnitt "VIRTUAL - <px>".
insert_entry() {
  local px=$1 entry=$2 tmp
  tmp=$(mktemp)
  awk -F'#' -v px="$px" -v idx=$((HOST_FIELD_INDEX + 1)) -v entry="$entry" '
    { lines[NR]=$0
      h=$idx; gsub(/[[:space:]]/, "", h)
      if ($0 !~ /^[#!]/ && h == px) last=NR
      if ($0 ~ /^SYSTEMS_EOF/ && !eof) eof=NR }
    END {
      for (i=1; i<=NR; i++) {
        if (!last && i == eof) {
          print "# VIRTUAL - " px; print "#################"; print entry; print "#"
        }
        print lines[i]
        if (last && i == last) print entry
      }
    }' "$SYSTEMS_FILE" > "$tmp"
  cat "$tmp" > "$SYSTEMS_FILE"
  rm -f "$tmp"
}

# Setzt das Host-Feld der Zeile mit ID=<vmid> und Host=<alt> auf <neu>.
move_entry() {
  local vmid=$1 old=$2 new=$3 tmp
  tmp=$(mktemp)
  awk -F'#' -v OFS='#' -v id="$vmid" -v old="$old" -v new="$new" -v idx=$((HOST_FIELD_INDEX + 1)) '
    {
      i=$2; gsub(/[[:space:]]/, "", i)
      h=$idx; gsub(/[[:space:]]/, "", h)
      if ($0 !~ /^[#!]/ && i == id && h == old) { $idx = sprintf("%-6s", new) }
      print
    }' "$SYSTEMS_FILE" > "$tmp"
  cat "$tmp" > "$SYSTEMS_FILE"
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# Vergleich
# --------------------------------------------------------------------------
CHANGES=()
NEEDS_REVIEW=0

if (( DRY_RUN )); then
  say "DRY-RUN Modus -- keine Aenderungen werden geschrieben"
elif [[ ! -d $(dirname "$SYSTEMS_FILE")/.git ]]; then
  cp "$SYSTEMS_FILE" "${SYSTEMS_FILE}.bak"
  say "Backup: ${SYSTEMS_FILE}.bak"
fi

for key in $(printf '%s\n' "${!LIVE[@]}" | sort -t'|' -k1,1 -k2,2n); do
  px=${key%%|*}
  vmid=${key#*|}
  IFS='|' read -r typ vname st ips os <<< "${LIVE[$key]}"

  if [[ $st != running ]]; then
    report STOPPED "$px" "$typ" "$vmid" "$vname" "$(first_ip "$ips")" "$st"
  fi

  if [[ -n ${INV_ENTRY[$key]+x} ]]; then
    IFS='|' read -r inv_name inv_ip <<< "${INV_ENTRY[$key]}"
    if [[ ${inv_name,,} != "${vname,,}" ]]; then
      report NAME "$px" "$typ" "$vmid" "$vname" "$inv_ip" "Inventar-Name ${inv_name}"
      NEEDS_REVIEW=1
    fi
    if [[ -n $ips ]] && ! ip_in_list "$inv_ip" "$ips"; then
      report IP "$px" "$typ" "$vmid" "$vname" "$inv_ip" "live ${ips}"
      NEEDS_REVIEW=1
    fi
    continue
  fi

  old_px=${INV_BY_ID["$vmid|${vname,,}"]:-}
  if [[ -n $old_px && $old_px != "$px" && -z ${LIVE["$old_px|$vmid"]+x} ]]; then
    report MOVED "$px" "$typ" "$vmid" "$vname" "$(first_ip "$ips")" "Host ${old_px} -> ${px}"
    if (( ! DRY_RUN )); then
      move_entry "$vmid" "$old_px" "$px"
      CHANGES+=("MOVED $vname ($vmid) ${old_px} -> ${px}")
    fi
    continue
  fi

  ip=$(first_ip "$ips")
  IFS='|' read -r bs flags hint <<< "$(analyse_guest "$px" "$typ" "$st" "$ip" "$os")"
  report NEW "$px" "$typ" "$vmid" "$vname" "${ip:-}" "BS=${bs} Flags=${flags// /,} (${hint})"
  if [[ $hint == kein\ SSH* ]]; then
    report NOSSH "$px" "$typ" "$vmid" "$vname" "$ip" "$hint"
    NEEDS_REVIEW=1
  fi
  if (( ! DRY_RUN )); then
    insert_entry "$px" "$(format_entry "$vmid" "$vname" "${ip:-}" "$bs" "$flags" "$px")"
    CHANGES+=("NEW $vname ($vmid) auf ${px}: BS=${bs} Flags=${flags// /,}")
  fi
done

for key in $(printf '%s\n' "${!INV_ENTRY[@]}" | sort); do
  px=${key%%|*}
  vmid=${key#*|}
  [[ -n ${PX_IP[$px]+x} && -n ${PX_OK[$px]+x} ]] || continue
  [[ -n ${LIVE[$key]+x} ]] && continue
  IFS='|' read -r inv_name inv_ip <<< "${INV_ENTRY[$key]}"
  moved_to=${LIVE_BY_ID["$vmid|${inv_name,,}"]:-}
  [[ -n $moved_to && $moved_to != "$px" ]] && continue
  report GONE "$px" - "$vmid" "$inv_name" "$inv_ip" "im Inventar, aber nicht mehr auf ${px}"
  NEEDS_REVIEW=1
done

# --------------------------------------------------------------------------
# Abschluss
# --------------------------------------------------------------------------
if (( ${#CHANGES[@]} > 0 )); then
  bash -n "$SYSTEMS_FILE" || { err "Inventar nach Aenderung syntaktisch kaputt: $SYSTEMS_FILE"; exit 2; }
  inv_dir=$(dirname "$SYSTEMS_FILE")
  if [[ -d $inv_dir/.git ]]; then
    git -C "$inv_dir" add "$(basename "$SYSTEMS_FILE")"
    git -C "$inv_dir" commit -q -m "sync-proxmox: $(printf '%s; ' "${CHANGES[@]}")" \
      && say "Aenderungen in ${inv_dir} committet."
  fi
fi

if [[ -n $REPORT_FILE ]]; then
  {
    printf '# sync-proxmox %s\n' "$(date -Is)"
    printf '# ART|PROXMOX-HOST|TYP|VMID|NAME|IP|DETAIL\n'
    if (( ${#REPORT_LINES[@]} > 0 )); then
      printf '%s\n' "${REPORT_LINES[@]}"
    fi
  } > "$REPORT_FILE"
fi

say "Sync abgeschlossen: ${#CHANGES[@]} Aenderung(en), ${#REPORT_LINES[@]} Befund(e)."
(( PX_FAILED )) && exit 2
(( NEEDS_REVIEW )) && exit 1
exit 0
