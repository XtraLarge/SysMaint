#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF_USAGE'
Verwendung:
  ./run-keys.sh full [--reset]
  ./run-keys.sh only IP-ODER-DNS [WEITERE...] [--reset]
  ./run-keys.sh --help
EOF_USAGE
}

mode=${1:-}

case "$mode" in
  ""|--help|-?)
    usage
    exit 0
    ;;
  full)
    shift
    ;;
  only)
    shift
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

reset_args=()
host_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      reset_args=(-- --reset)
      shift
      ;;
    *)
      host_args+=("$1")
      shift
      ;;
  esac
done

cmd=("$BASE_DIR/manage.sh" KY "$BASE_DIR/tasks/keys_task.sh")

if [[ $mode == "only" ]]; then
  (( ${#host_args[@]} > 0 )) || { usage >&2; exit 1; }
  cmd+=(--only "${host_args[@]}")
elif (( ${#host_args[@]} > 0 )); then
  usage >&2
  exit 1
fi

cmd+=("${reset_args[@]}")
exec "${cmd[@]}"
