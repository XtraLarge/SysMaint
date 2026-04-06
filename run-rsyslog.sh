#!/usr/bin/env bash
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$BASE_DIR/manage.sh" RS "$BASE_DIR/tasks/rsyslog_task.sh" "$@"
