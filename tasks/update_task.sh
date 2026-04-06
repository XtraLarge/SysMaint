#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

supports_update() {
  [[ ${BS:-} =~ ^(D|U|S)$ ]]
}

queue_reboot_if_needed() {
  local need_reboot=0

  if [[ ${FR:-0} == "1" ]]; then
    need_reboot=1
  elif run_ssh '[[ -f /var/run/reboot-required ]]'; then
    need_reboot=1
  fi

  if (( need_reboot == 1 )); then
    info "Merke Reboot für ${Name} vor"
    printf '%s|%s|%s
' "$Name" "$IP" "${JP:-}" >> "$REBOOT_QUEUE_FILE"
  else
    info "Kein Reboot nötig für ${Name}"
  fi
}

build_update_script() {
  case "${BS:-}" in
    D)
      cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPT='-y -qq -o DPkg::Options::=--force-confold -o DPkg::Options::=--force-overwrite -o DPkg::Options::=--force-overwrite-dir --trivial-only=no'
apt-get update
dpkg --configure -a
apt-get $APT_OPT --fix-broken install
apt-get $APT_OPT install sudo at
apt-get $APT_OPT dist-upgrade
apt-get $APT_OPT autoremove --purge
apt-get clean
REMOTE
      ;;
    U)
      cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPT='-y -qq -o DPkg::Options::=--force-confold -o DPkg::Options::=--force-overwrite -o DPkg::Options::=--force-overwrite-dir --trivial-only=no'
apt-get update
dpkg --configure -a
apt-get $APT_OPT --fix-broken install
apt-get $APT_OPT autoremove --purge
apt-get clean
univention-upgrade --noninteractive --ignoressh --ignoreterm
apt-get $APT_OPT install sudo at
REMOTE
      ;;
    S)
      cat <<'REMOTE'
set -euo pipefail
ZYPPER_OPT='--non-interactive --no-gpg-checks --quiet'
zypper $ZYPPER_OPT refresh
zypper $ZYPPER_OPT install sudo at
zypper $ZYPPER_OPT update
REMOTE
      ;;
    *)
      return 1
      ;;
  esac
}

supports_update || {
  warn "${Name}: Betriebssystem ${BS:-?} für Update nicht unterstützt"
  exit 0
}

remove_known_host
info "Starte Update auf ${Name} (${BS})"
run_ssh_bash "$(build_update_script)"
queue_reboot_if_needed
