#!/usr/bin/env bash
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$BASE_DIR/manage.sh" UP "$BASE_DIR/tasks/update_task.sh" "$@"
