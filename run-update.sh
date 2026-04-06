#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF_USAGE'
Verwendung:
  ./run-update.sh full
  ./run-update.sh --only IP-ODER-DNS
  ./run-update.sh --help
EOF_USAGE
}

case "${1:-}" in
  ""|--help|-?)
    usage
    exit 0
    ;;
  full)
    shift
    exec "$BASE_DIR/manage.sh" UP "$BASE_DIR/tasks/update_task.sh" "$@"
    ;;
  --only)
    exec "$BASE_DIR/manage.sh" UP "$BASE_DIR/tasks/update_task.sh" "$@"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
