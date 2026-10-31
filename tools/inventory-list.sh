#!/usr/bin/env bash
# Gibt das Inventar (.Systems.sh) als TSV aus: eine Kopfzeile, danach eine
# Zeile je aktivem Eintrag. Grundlage fuer die Python-Werkzeuge.
#
# Spalten: name ip bs up ky typ id fr bk rs sh af jp sg host rb

set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$BASE_DIR/lib/common.sh"

DEFAULT_SYSTEMS_FILE=$BASE_DIR/.Systems.sh
[[ -r /etc/sysmaint/.Systems.sh ]] && DEFAULT_SYSTEMS_FILE=/etc/sysmaint/.Systems.sh
if [[ -z ${SYSTEMS_FILE:-} || ${SYSTEMS_FILE} == "./.Systems.sh" ]]; then
  SYSTEMS_FILE=$DEFAULT_SYSTEMS_FILE
fi

require_file "$SYSTEMS_FILE"
# shellcheck source=/dev/null
source "$SYSTEMS_FILE"
IFS=$' \t\n'

printf 'name\tip\tbs\tup\tky\ttyp\tid\tfr\tbk\trs\tsh\taf\tjp\tsg\thost\trb\n'
for line in "${HOSTNAMES[@]}"; do
  [[ $line == \#* || $line == \!* || -z ${line//[[:space:]]/} ]] && continue
  LINE=$line
  element
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${Name:-}" "${IP:-}" "${BS:-}" "${UP:-0}" "${KY:-0}" "${Typ:-}" "${ID:-}" \
    "${FR:-0}" "${BK:-0}" "${RS:-0}" "${SH:-0}" "${AF:-0}" "${JP:-}" "${SG:-}" "${Host:-}" "${RB:-}"
done
