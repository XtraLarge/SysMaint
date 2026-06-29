#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

bash -n \
  "$BASE_DIR/config.sh" \
  "$BASE_DIR/manage.sh" \
  "$BASE_DIR/lib/common.sh" \
  "$BASE_DIR/tasks/update_task.sh" \
  "$BASE_DIR/tasks/keys_task.sh" \
  "$BASE_DIR/tasks/rsyslog_task.sh" \
  "$BASE_DIR/tasks/shell_task.sh" \
  "$BASE_DIR/tasks/autofs_task.sh" \
  "$BASE_DIR/tools/sync-proxmox.sh" \
  "$BASE_DIR/run-update.sh" \
  "$BASE_DIR/run-keys.sh" \
  "$BASE_DIR/run-rsyslog.sh" \
  "$BASE_DIR/run-shell.sh" \
  "$BASE_DIR/run-autofs.sh" \
  "$BASE_DIR/run-proxmox.sh" \
  "$BASE_DIR/run-status.sh" \
  "$BASE_DIR/.Systems.sh"

# Naming-guard: prueft NUR die GETRACKTEN Dateien (genau das, was tatsaechlich
# ins oeffentliche origin gelangt) statt des gesamten Working-Tree. Sonst
# blocken lokale, gitignored Dateien (z.B. SESSION_NOTES.md) faelschlich den
# Lauf, obwohl sie nie gepusht werden (#261).
# Gesucht: private IP-Bereiche, interne lokale Domains/Namen, SSH-/Private-Keys
# und secret-artige Zuweisungen (password=/token=/api_key= mit Literalwert;
# Variablen-Referenzen wie =$VAR oder =${VAR} matchen bewusst NICHT).
PATTERN='(192\.168\.|10\.[0-9]+\.|ssh-rsa|BEGIN .*PRIVATE KEY|fritz\.box|derwerres|ConAction|Xtra|Hans-Willi|XLBackup|(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*["'\'']?[A-Za-z0-9_./+-]{6,})'

# check.sh selbst enthaelt die Muster-Strings; CHANGELOG kann Release-Notizen
# mit Namen enthalten -> beide vom Inhalts-Scan ausnehmen.
if (cd "$BASE_DIR" && git ls-files -z ':!:scripts/check.sh' ':!:CHANGELOG.md' \
      | xargs -0 -r grep -InE "$PATTERN" --); then
  echo "Sensitive-looking data found. Review before commit." >&2
  exit 1
fi

printf 'Checks passed.\n'
