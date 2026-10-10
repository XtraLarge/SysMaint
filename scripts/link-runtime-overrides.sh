#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

link_if_present() {
  local source_path=$1
  local target_path=$2

  if [[ -e $source_path ]]; then
    ln -sfn "$source_path" "$target_path"
    printf 'Linked %s -> %s\n' "$target_path" "$source_path"
  else
    rm -f "$target_path"
    printf 'Removed %s (source missing)\n' "$target_path"
  fi
}

link_if_present /etc/sysmaint/.Systems.sh "$BASE_DIR/.Systems.override.sh"
link_if_present /etc/sysmaint/config.sh "$BASE_DIR/config.override.sh"
link_if_present /etc/sysmaint/keys "$BASE_DIR/keys.override"
link_if_present /etc/sysmaint/repository "$BASE_DIR/repository.override"

# Ensure the local pre-commit guard is installed (defense-in-depth before push).
# Idempotent: (re)installs .git/hooks/pre-commit only when it is missing, so the
# guard survives a fresh clone or a hooks reset. The CI gate
# (.github/workflows/ci.yml) stays authoritative; this is the local pre-push net.
ensure_precommit_hook() {
  [[ -d $BASE_DIR/.git ]] || return 0
  if [[ -f $BASE_DIR/.git/hooks/pre-commit ]]; then
    return 0
  fi

  local pre_commit=""
  if command -v pre-commit >/dev/null 2>&1; then
    pre_commit=$(command -v pre-commit)
  elif [[ -x $HOME/.local/bin/pre-commit ]]; then
    pre_commit=$HOME/.local/bin/pre-commit
  fi

  if [[ -z $pre_commit ]]; then
    printf 'pre-commit not found; skipping hook install (see INSTALL.md)\n' >&2
    return 0
  fi

  if ( cd "$BASE_DIR" && "$pre_commit" install >/dev/null ); then
    printf 'Installed pre-commit hook -> %s/.git/hooks/pre-commit\n' "$BASE_DIR"
  else
    printf 'pre-commit install failed; run manually: (cd %s && pre-commit install)\n' "$BASE_DIR" >&2
  fi
}

ensure_precommit_hook
