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
link_if_present /etc/sysmaint/keys "$BASE_DIR/keys.override"
