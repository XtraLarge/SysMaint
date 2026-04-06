#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

cd "$BASE_DIR"

current_branch=$(git branch --show-current)
[[ $current_branch == "main" ]] || {
  echo "Local update is only supported on main. Current branch: $current_branch" >&2
  exit 1
}

git diff --quiet
git diff --cached --quiet

git fetch origin
git pull --ff-only origin main

if [[ -x ./scripts/check.sh ]]; then
  ./scripts/check.sh
fi

printf 'SysMaint updated to %s\n' "$(git rev-parse --short HEAD)"
