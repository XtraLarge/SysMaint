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
SHELL_ALIASES_DIR=${SHELL_ALIASES_DIR:-$SHELL_REPOSITORY_DIR/aliases}
SHELL_BASH_ALIASES_FILE=${SHELL_BASH_ALIASES_FILE:-$SHELL_REPOSITORY_DIR/.bash_aliases}
SHELL_BASH_LOCAL_FILE=${SHELL_BASH_LOCAL_FILE:-$SHELL_REPOSITORY_DIR/.bash_local}
SHELL_VIMRC_FILE=${SHELL_VIMRC_FILE:-$SHELL_REPOSITORY_DIR/.vimrc}

shell_packages_for_current_os() {
  local var_name="SHELL_PACKAGES_${BS:-}"
  local packages

  case "${BS:-}" in
    D|U)
      packages="bash-completion vim less figlet"
      ;;
    S)
      packages="vim less"
      ;;
    *)
      packages=${SHELL_PACKAGES_DEFAULT:-}
      ;;
  esac

  if declare -p "$var_name" >/dev/null 2>&1; then
    packages=${!var_name}
  fi

  printf '%s' "$packages"
}

build_alias_content() {
  ALIAS_CONTENT=""
  local alias_file group group_file host_file
  local -a matches=()
  local nocaseglob_was_set=0
  local shell_groups=${SG:-}

  if [[ -d $SHELL_ALIASES_DIR ]]; then
    shopt -q nocaseglob && nocaseglob_was_set=1
    shopt -s nocaseglob

    for alias_file in "$SHELL_ALIASES_DIR"/base_*.sh; do
      [[ -f $alias_file ]] || continue
      dbg "Lade Basis-Aliase: $(basename "$alias_file")"
      ALIAS_CONTENT+=$(cat "$alias_file")
      ALIAS_CONTENT+=$'\n'
    done

    if [[ -n $shell_groups ]]; then
      IFS=',' read -r -a matches <<< "$shell_groups"
      for group in "${matches[@]}"; do
        group=${group//[[:space:]]/}
        [[ -n $group ]] || continue
        matches=("$SHELL_ALIASES_DIR"/group_"$group".sh)
        group_file=${matches[0]-}
        if [[ -f ${group_file:-} ]]; then
          info "Alias-Gruppe '${group}' wird hinzugefuegt"
          ALIAS_CONTENT+=$(cat "$group_file")
          ALIAS_CONTENT+=$'\n'
        else
          warn "Alias-Gruppe '${group}' definiert, aber Datei nicht gefunden"
        fi
      done
    fi

    matches=("$SHELL_ALIASES_DIR"/host_"$Name".sh)
    host_file=${matches[0]-}
    if [[ -f ${host_file:-} ]]; then
      info "Host-spezifische Aliase fuer '${Name}' werden hinzugefuegt"
      ALIAS_CONTENT+=$(cat "$host_file")
      ALIAS_CONTENT+=$'\n'
    fi

    (( nocaseglob_was_set )) || shopt -u nocaseglob
  fi

  if [[ -n $ALIAS_CONTENT ]]; then
    return 0
  fi

  if [[ -f $SHELL_BASH_ALIASES_FILE ]]; then
    info "Nutze Fallback-Aliasdatei $(basename "$SHELL_BASH_ALIASES_FILE")"
    ALIAS_CONTENT=$(cat "$SHELL_BASH_ALIASES_FILE")
    return 0
  fi

  require_file "$SHELL_BASH_LOCAL_FILE"
  info "Nutze Legacy-Aliasdatei $(basename "$SHELL_BASH_LOCAL_FILE")"
  ALIAS_CONTENT=$(cat "$SHELL_BASH_LOCAL_FILE")
}

run_task() {
  info "Installiere Shell-Konfiguration auf ${Name}"

  local shell_packages
  local alias_content_b64
  local vimrc_content_b64
  build_alias_content
  shell_packages=$(shell_packages_for_current_os)
  require_file "$SHELL_VIMRC_FILE"
  alias_content_b64=$(printf '%s' "$ALIAS_CONTENT" | base64 | tr -d '\n')
  vimrc_content_b64=$(base64 < "$SHELL_VIMRC_FILE" | tr -d '\n')

  local remote_script
  remote_script="$(cat <<EOF_REMOTE
set -euo pipefail

BASH_ALIASES_BEGIN="# BEGIN SYSMAINT MANAGED BASH_ALIASES"
BASH_ALIASES_END="# END SYSMAINT MANAGED BASH_ALIASES"
VIMRC_BEGIN="\" BEGIN SYSMAINT MANAGED VIMRC"
VIMRC_END="\" END SYSMAINT MANAGED VIMRC"

export DEBIAN_FRONTEND=noninteractive

SHELL_PACKAGES="${shell_packages}"

install_requested_packages() {
  local missing=()
  local pkg

  [[ -n \$SHELL_PACKAGES ]] || return 0

  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
    for pkg in \$SHELL_PACKAGES; do
      dpkg-query -W -f='\${Status}\\n' "\$pkg" 2>/dev/null | grep -Fqx 'install ok installed' || missing+=("\$pkg")
    done

    if (( \${#missing[@]} > 0 )); then
      apt-get update
      apt-get -y install "\${missing[@]}"
    fi
    return 0
  fi

  if command -v zypper >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    for pkg in \$SHELL_PACKAGES; do
      rpm -q "\$pkg" >/dev/null 2>&1 || missing+=("\$pkg")
    done

    if (( \${#missing[@]} > 0 )); then
      zypper --non-interactive install "\${missing[@]}"
    fi
  fi
}

install_requested_packages

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
  local target_file=\$1
  local begin_marker=\$2
  local end_marker=\$3
  local content_file=\$4
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

TMP_BASH_ALIASES_CONTENT=\$(mktemp)
TMP_VIMRC_CONTENT=\$(mktemp)

printf '%s' '${alias_content_b64}' | base64 -d > "\$TMP_BASH_ALIASES_CONTENT"
printf '%s' '${vimrc_content_b64}' | base64 -d > "\$TMP_VIMRC_CONTENT"

update_managed_file /root/.bash_aliases "\$BASH_ALIASES_BEGIN" "\$BASH_ALIASES_END" "\$TMP_BASH_ALIASES_CONTENT"
update_managed_file /root/.vimrc "\$VIMRC_BEGIN" "\$VIMRC_END" "\$TMP_VIMRC_CONTENT"
rm -f "\$TMP_BASH_ALIASES_CONTENT" "\$TMP_VIMRC_CONTENT"

if [[ ! -f /root/.bashrc ]]; then
  touch /root/.bashrc
fi

sed -i '/\[\[ -f \/root\/\.bashxl \]\] && \. \/root\/\.bashxl/d' /root/.bashrc
sed -i '/\[\[ -f \/root\/\.bash_local \]\] && \. \/root\/\.bash_local/d' /root/.bashrc
grep -Fqx '[[ -f /root/.bash_aliases ]] && . /root/.bash_aliases' /root/.bashrc 2>/dev/null || \
  printf '%s\n' '[[ -f /root/.bash_aliases ]] && . /root/.bash_aliases' >> /root/.bashrc

exit 0
EOF_REMOTE
)"

  run_ssh_bash "$remote_script"
}

run_task
