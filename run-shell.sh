#!/usr/bin/env bash
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$BASE_DIR/manage.sh" SH "$BASE_DIR/tasks/shell_task.sh" "$@"
