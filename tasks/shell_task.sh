#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DEFAULT_SHELL_REPOSITORY_DIR=$SCRIPT_DIR/../repository
if [[ -d /etc/sysmaint/repository ]]; then
  DEFAULT_SHELL_REPOSITORY_DIR=/etc/sysmaint/repository
fi

SHELL_REPOSITORY_DIR=${SHELL_REPOSITORY_DIR:-$DEFAULT_SHELL_REPOSITORY_DIR}
SHELL_BASH_LOCAL_FILE=${SHELL_BASH_LOCAL_FILE:-$SHELL_REPOSITORY_DIR/.bash_local}
SHELL_VIMRC_FILE=${SHELL_VIMRC_FILE:-$SHELL_REPOSITORY_DIR/.vimrc}

run_task() {
  info "Installiere Shell-Konfiguration auf ${Name}"

  local remote_script
  remote_script="$(cat <<EOF_REMOTE
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

cat > /root/.bash_local <<'EOF_BASH_LOCAL'
$(cat "$SHELL_BASH_LOCAL_FILE")
EOF_BASH_LOCAL

cat > /root/.vimrc <<'EOF_VIM'
$(cat "$SHELL_VIMRC_FILE")
EOF_VIM

if [[ ! -f /root/.bashrc ]]; then
  touch /root/.bashrc
fi

grep -Fqx '[[ -f /root/.bash_local ]] && . /root/.bash_local' /root/.bashrc 2>/dev/null || \
  printf '%s\n' '[[ -f /root/.bash_local ]] && . /root/.bash_local' >> /root/.bashrc

exit 0
EOF_REMOTE
)"

  run_ssh_bash "$remote_script"
}

run_task
