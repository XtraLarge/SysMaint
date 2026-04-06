#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

bash -n \
  "$BASE_DIR/manage.sh" \
  "$BASE_DIR/lib/common.sh" \
  "$BASE_DIR/tasks/update_task.sh" \
  "$BASE_DIR/tasks/keys_task.sh" \
  "$BASE_DIR/tasks/rsyslog_task.sh" \
  "$BASE_DIR/tasks/shell_task.sh" \
  "$BASE_DIR/tasks/autofs_task.sh" \
  "$BASE_DIR/run-update.sh" \
  "$BASE_DIR/run-keys.sh" \
  "$BASE_DIR/run-rsyslog.sh" \
  "$BASE_DIR/run-shell.sh" \
  "$BASE_DIR/run-autofs.sh" \
  "$BASE_DIR/run-status.sh" \
  "$BASE_DIR/.Systems.sh"

grep -RInE '(192\.168\.|10\.[0-9]+\.|ssh-rsa|BEGIN .*PRIVATE KEY|fritz\.box|ConAction|Xtra|Hans-Willi|XLBackup)' \
  "$BASE_DIR" \
  --exclude-dir=.git \
  --exclude-dir=logs \
  --exclude-dir=keys.override \
  --exclude-dir=repository.override \
  --exclude=CHANGELOG.md \
  --exclude=check.sh \
  --exclude=.Systems.override.sh \
  && {
    echo "Sensitive-looking data found. Review before commit." >&2
    exit 1
  } || true

printf 'Checks passed.\n'
