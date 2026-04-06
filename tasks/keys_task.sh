#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

DEFAULT_KEY_DIR=$BASE_DIR/keys
if [[ -d /etc/sysmaint/keys ]]; then
  DEFAULT_KEY_DIR=/etc/sysmaint/keys
fi

KEY_DIR=${KEY_DIR:-$DEFAULT_KEY_DIR}
NEW_KEY_FILE=${NEW_KEY_FILE:-$KEY_DIR/new_user.pub}
OLD_KEY_FILE=${OLD_KEY_FILE:-$KEY_DIR/old_user.pub}
BACKUP_KEY_FILE=${BACKUP_KEY_FILE:-$KEY_DIR/backup.pub}
RESET_KEYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET_KEYS=1
      shift
      ;;
    *)
      err "Unbekannte Option für keys_task.sh: $1"
      exit 1
      ;;
  esac
done

require_file "$NEW_KEY_FILE"
require_file "$OLD_KEY_FILE"
if [[ ${BK:-0} == "1" ]]; then
  require_file "$BACKUP_KEY_FILE"
fi

new_key=$(<"$NEW_KEY_FILE")
old_key=$(<"$OLD_KEY_FILE")
desired_keys=$(printf '%s\n%s\n' "$old_key" "$new_key")
if [[ ${BK:-0} == "1" ]]; then
  backup_key=$(<"$BACKUP_KEY_FILE")
  desired_keys+=$(printf '%s\n' "$backup_key")
fi

desired_keys=$(printf '%s\n' "$desired_keys" | awk 'NF && !seen[$0]++')
managed_keys=$(printf '%s\n' "$desired_keys" | awk 'NF { if (count++) print ""; print }')

remote_script='set -euo pipefail
AUTH_DIR="/root/.ssh"
AUTH_FILE="${AUTH_DIR}/authorized_keys"
BACKUP_FILE="${AUTH_FILE}.bak"
MANAGED_BEGIN="# BEGIN SYSMAINT MANAGED KEYS"
MANAGED_END="# END SYSMAINT MANAGED KEYS"
TMP_MANAGED="$(mktemp)"
TMP_FILE="$(mktemp)"
RESET_KEYS="${1:-0}"

mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"

if [[ -f "$AUTH_FILE" ]]; then
  cp -f "$AUTH_FILE" "$BACKUP_FILE"
fi

cat > "$TMP_MANAGED"

if [[ "$RESET_KEYS" == "1" ]]; then
  : > "$TMP_FILE"
elif [[ -f "$AUTH_FILE" ]]; then
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" "
    \$0 == begin { skip = 1; next }
    \$0 == end { skip = 0; next }
    skip == 0 { print }
  " "$AUTH_FILE" > "$TMP_FILE"
else
  : > "$TMP_FILE"
fi

if [[ -s "$TMP_FILE" ]]; then
  printf "\n" >> "$TMP_FILE"
fi

printf "%s\n" "$MANAGED_BEGIN" >> "$TMP_FILE"
cat "$TMP_MANAGED" >> "$TMP_FILE"
printf "%s\n" "$MANAGED_END" >> "$TMP_FILE"

chmod 600 "$TMP_FILE"
install -m 600 "$TMP_FILE" "$AUTH_FILE"
rm -f "$TMP_FILE" "$TMP_MANAGED"
'

if (( RESET_KEYS == 1 )); then
  info "Aktualisiere authorized_keys auf ${Name} im Reset-Modus"
else
  info "Aktualisiere authorized_keys auf ${Name}"
fi
printf '%s\n' "$managed_keys" | run_ssh_with_stdin "$remote_script" "$RESET_KEYS"
