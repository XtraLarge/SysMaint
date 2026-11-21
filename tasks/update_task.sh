#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

supports_update() {
  [[ ${BS:-} =~ ^(D|P|U|S)$ ]]
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
    D|P)
      cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
APT_OPT='-y -qq -o DPkg::Lock::Timeout=600 -o DPkg::Options::=--force-confold -o DPkg::Options::=--force-overwrite -o DPkg::Options::=--force-overwrite-dir --trivial-only=no'
# Auf laufende apt/dpkg-Prozesse warten (apt-daily, unattended-upgrades),
# sonst bricht dpkg --configure -a an der Frontend-Sperre ab.
# unattended-upgrade-shutdown laeuft dauerhaft und hat denselben
# Prozessnamen, deshalb Muster auf bin/unattended-upgrade.
sysmaint_wait_apt() {
  command -v pgrep >/dev/null 2>&1 || return 0
  _w=0
  while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 \
     || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f "bin/unattended-upgrade( |$)" >/dev/null 2>&1 \
     || pgrep -x apt.systemd.dai >/dev/null 2>&1; do
    if [ "$_w" -ge 600 ]; then
      echo "apt/dpkg nach 600 s noch belegt, versuche es trotzdem" >&2
      return 0
    fi
    sleep 5
    _w=$((_w + 5))
  done
}
sysmaint_wait_apt
apt-get -o DPkg::Lock::Timeout=600 update
sysmaint_wait_apt
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
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
APT_OPT='-y -qq -o DPkg::Lock::Timeout=600 -o DPkg::Options::=--force-confold -o DPkg::Options::=--force-overwrite -o DPkg::Options::=--force-overwrite-dir --trivial-only=no'
# Auf laufende apt/dpkg-Prozesse warten (apt-daily, unattended-upgrades),
# sonst bricht dpkg --configure -a an der Frontend-Sperre ab.
# unattended-upgrade-shutdown laeuft dauerhaft und hat denselben
# Prozessnamen, deshalb Muster auf bin/unattended-upgrade.
sysmaint_wait_apt() {
  command -v pgrep >/dev/null 2>&1 || return 0
  _w=0
  while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 \
     || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f "bin/unattended-upgrade( |$)" >/dev/null 2>&1 \
     || pgrep -x apt.systemd.dai >/dev/null 2>&1; do
    if [ "$_w" -ge 600 ]; then
      echo "apt/dpkg nach 600 s noch belegt, versuche es trotzdem" >&2
      return 0
    fi
    sleep 5
    _w=$((_w + 5))
  done
}
sysmaint_wait_apt
apt-get -o DPkg::Lock::Timeout=600 update
sysmaint_wait_apt
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
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
