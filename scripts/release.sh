#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./scripts/release.sh <version> [title]

Example:
  ./scripts/release.sh v0.2.0 "SSH key and workflow improvements"
EOF_USAGE
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 1
}

version=$1
title=${2:-}

[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Version must look like vMAJOR.MINOR.PATCH" >&2
  exit 1
}

current_branch=$(git branch --show-current)
[[ $current_branch == "main" ]] || {
  echo "Releases must be created from main." >&2
  exit 1
}

git diff --quiet
git diff --cached --quiet

git pull --ff-only origin main
./scripts/check.sh

if git rev-parse "$version" >/dev/null 2>&1; then
  echo "Tag already exists: $version" >&2
  exit 1
fi

release_date=$(date +%F)
tmp_changelog=$(mktemp)

{
  printf '# Changelog\n\n'
  printf '## %s - %s\n\n' "$version" "$release_date"
  if [[ -n $title ]]; then
    printf '- %s\n' "$title"
  else
    printf -- '- Release created.\n'
  fi
  printf '\n'
  if [[ -f CHANGELOG.md ]]; then
    sed '1d' CHANGELOG.md
  fi
} > "$tmp_changelog"

mv "$tmp_changelog" CHANGELOG.md
git add CHANGELOG.md
git commit -m "Prepare release $version"
git tag -a "$version" -m "Release $version"
git push origin main
git push origin "$version"

printf 'Released %s\n' "$version"
