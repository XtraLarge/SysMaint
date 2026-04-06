#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF_USAGE'
Verwendung:
  ./run-rsyslog.sh full
  ./run-rsyslog.sh only IP-ODER-DNS
  ./run-rsyslog.sh --help
EOF_USAGE
}

case "${1:-}" in
  ""|--help|-?)
    usage
    exit 0
    ;;
  full)
    shift
    exec "$BASE_DIR/manage.sh" RS "$BASE_DIR/tasks/rsyslog_task.sh" "$@"
    ;;
  only)
    shift
    exec "$BASE_DIR/manage.sh" RS "$BASE_DIR/tasks/rsyslog_task.sh" --only "$@"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
