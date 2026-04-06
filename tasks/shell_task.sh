#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

run_task() {
  info "Installiere Shell-Konfiguration auf ${Name}"

  local remote_script
  remote_script="$(cat <<'EOF_REMOTE'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get -y install bash-completion vim less
fi

# Locale sauber auf de_DE.UTF-8 setzen
if [[ -f /etc/locale.gen ]]; then
  if grep -Eq '^[#[:space:]]*de_DE\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
    sed -i 's/^[#[:space:]]*de_DE\.UTF-8[[:space:]]\+UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
  else
    printf '%s\n' 'de_DE.UTF-8 UTF-8' >> /etc/locale.gen
  fi
  locale-gen de_DE.UTF-8
fi

if command -v update-locale >/dev/null 2>&1; then
  update-locale LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8
fi

if command -v debconf-set-selections >/dev/null 2>&1 && command -v dpkg-reconfigure >/dev/null 2>&1; then
  printf '%s\n' \
    'locales locales/default_environment_locale select de_DE.UTF-8' \
    'locales locales/locales_to_be_generated multiselect de_DE.UTF-8 UTF-8' \
    | debconf-set-selections
  dpkg-reconfigure -f noninteractive locales
fi

# Bash-Aliase / Grundkonfiguration
if [[ ! -f /root/.bash_aliases ]]; then
  touch /root/.bash_aliases
fi

append_alias() {
  local line="$1"
  local file="/root/.bash_aliases"
  grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

append_alias "alias ll='ls -alF'"
append_alias "alias la='ls -A'"
append_alias "alias l='ls -CF'"
append_alias "alias cls='clear'"
append_alias "alias ..='cd ..'"
append_alias "alias ...='cd ../..'"

if [[ ! -f /root/.vimrc ]]; then
  cat > /root/.vimrc <<'EOF_VIM'
set nocompatible
set backspace=indent,eol,start
syntax on
set number
set mouse=
EOF_VIM
fi

if [[ ! -f /root/.bashrc ]]; then
  touch /root/.bashrc
fi

grep -Fqx '[[ -f /root/.bash_aliases ]] && . /root/.bash_aliases' /root/.bashrc 2>/dev/null || \
  printf '%s\n' '[[ -f /root/.bash_aliases ]] && . /root/.bash_aliases' >> /root/.bashrc

exit 0
EOF_REMOTE
)"

  run_ssh_bash "$remote_script"
}

run_task

