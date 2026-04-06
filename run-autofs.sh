#!/usr/bin/env bash
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$BASE_DIR/manage.sh" AF "$BASE_DIR/tasks/autofs_task.sh" "$@"
