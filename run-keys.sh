#!/usr/bin/env bash
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$BASE_DIR/manage.sh" KY "$BASE_DIR/tasks/keys_task.sh" "$@"
