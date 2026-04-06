#!/usr/bin/env bash
set -euo pipefail

current_branch=$(git branch --show-current)

[[ -n $current_branch && $current_branch != "main" ]] || {
  echo "Open PRs only from a topic branch, not from main." >&2
  exit 1
}

git push -u origin "$current_branch"
gh pr create --fill
