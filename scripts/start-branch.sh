#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./scripts/start-branch.sh <type> <topic>

Examples:
  ./scripts/start-branch.sh fix ssh-key-rollout
  ./scripts/start-branch.sh docs installation-guide

Allowed types:
  feature, fix, docs, ops
EOF_USAGE
}

[[ $# -eq 2 ]] || {
  usage >&2
  exit 1
}

type=$1
topic=$2

case "$type" in
  feature|fix|docs|ops)
    ;;
  *)
    echo "Unsupported branch type: $type" >&2
    usage >&2
    exit 1
    ;;
esac

branch="${type}/${topic}"

git fetch origin
git checkout main
git pull --ff-only origin main
git checkout -b "$branch"

printf 'Created branch: %s\n' "$branch"
