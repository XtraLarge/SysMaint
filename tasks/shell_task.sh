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

BASH_LOCAL_BEGIN="# BEGIN SYSMAINT MANAGED BASH_LOCAL"
BASH_LOCAL_END="# END SYSMAINT MANAGED BASH_LOCAL"
VIMRC_BEGIN="\" BEGIN SYSMAINT MANAGED VIMRC"
VIMRC_END="\" END SYSMAINT MANAGED VIMRC"

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

update_managed_file() {
  local target_file=$1
  local begin_marker=$2
  local end_marker=$3
  local content_file=$4
  local base_file
  local output_file

  base_file=\$(mktemp)
  output_file=\$(mktemp)

  if [[ -f \$target_file ]]; then
    awk -v begin="\$begin_marker" -v end="\$end_marker" '
      \$0 == begin { skip = 1; next }
      \$0 == end { skip = 0; next }
      skip == 0 { print }
    ' "\$target_file" > "\$base_file"
  else
    : > "\$base_file"
  fi

  cat "\$base_file" > "\$output_file"
  if [[ -s \$output_file ]]; then
    printf "\\n" >> "\$output_file"
  fi

  printf "%s\\n" "\$begin_marker" >> "\$output_file"
  cat "\$content_file" >> "\$output_file"
  printf "%s\\n" "\$end_marker" >> "\$output_file"

  install -m 0644 "\$output_file" "\$target_file"
  rm -f "\$base_file" "\$output_file"
}

TMP_BASH_LOCAL_CONTENT=\$(mktemp)
TMP_VIMRC_CONTENT=\$(mktemp)

cat > "\$TMP_BASH_LOCAL_CONTENT" <<'EOF_BASH_LOCAL'
$(cat "$SHELL_BASH_LOCAL_FILE")
EOF_BASH_LOCAL

cat > "\$TMP_VIMRC_CONTENT" <<'EOF_VIM'
$(cat "$SHELL_VIMRC_FILE")
EOF_VIM

update_managed_file /root/.bash_local "\$BASH_LOCAL_BEGIN" "\$BASH_LOCAL_END" "\$TMP_BASH_LOCAL_CONTENT"
update_managed_file /root/.vimrc "\$VIMRC_BEGIN" "\$VIMRC_END" "\$TMP_VIMRC_CONTENT"
rm -f "\$TMP_BASH_LOCAL_CONTENT" "\$TMP_VIMRC_CONTENT"

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
