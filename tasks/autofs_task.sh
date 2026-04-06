#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

AUTOFS_BASEDIR=${AUTOFS_BASEDIR:-/etc/auto.master.d}
AUTOFS_MAPS_DIR=${AUTOFS_MAPS_DIR:-$AUTOFS_BASEDIR/maps}
AUTOFS_FILESYSTEMS=${AUTOFS_FILESYSTEMS:-loop sshfs cifs nfs}
AUTOFS_SSH_WRAPPERS_DIR=${AUTOFS_SSH_WRAPPERS_DIR:-/etc/sysmaint/autofs-ssh}
AUTOFS_RELOAD_MARKER=${AUTOFS_RELOAD_MARKER:-}
AUTOFS_CHANGED=0
AUTOFS_RESET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      AUTOFS_RESET=1
      shift
      ;;
    *)
      err "Unbekannte Option für autofs_task.sh: $1"
      exit 1
      ;;
  esac
done
autofs_packages_for_current_os() {
  local var_name="AUTOFS_PACKAGES_${BS:-}"
  local packages

  case "${BS:-}" in
    D|U)
      packages="autofs cifs-utils nfs-common sshfs"
      ;;
    S)
      packages="autofs cifs-utils nfs-client sshfs"
      ;;
    *)
      packages=${AUTOFS_PACKAGES_DEFAULT:-}
      ;;
  esac

  if declare -p "$var_name" >/dev/null 2>&1; then
    packages=${!var_name}
  fi

  printf '%s' "$packages"
}

ensure_local_packages() {
  local packages missing=() pkg
  packages=$(autofs_packages_for_current_os)
  [[ -n $packages ]] || return 0

  exec 9>/tmp/sysmaint-autofs-packages.lock
  flock 9

  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    for pkg in $packages; do
      dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -Fqx 'install ok installed' || missing+=("$pkg")
    done

    if (( ${#missing[@]} > 0 )); then
      info "Installiere fehlende AutoFS-Pakete: ${missing[*]}"
      apt-get update
      apt-get -y install "${missing[@]}"
    fi
    flock -u 9
    return 0
  fi

  if command -v zypper >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    for pkg in $packages; do
      rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if (( ${#missing[@]} > 0 )); then
      info "Installiere fehlende AutoFS-Pakete: ${missing[*]}"
      zypper --non-interactive install "${missing[@]}"
    fi
    flock -u 9
    return 0
  fi

  flock -u 9
  warn "Kein unterstützter Paketmanager für AutoFS-Paketprüfung gefunden"
}

ensure_dir() {
  local dir=$1
  [[ -d $dir ]] || mkdir -p "$dir"
}

sanitize_filename() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

ensure_sshfs_jump_wrapper() {
  local jump_host=$1
  local safe_name wrapper_path current_content desired_content

  safe_name=$(sanitize_filename "$jump_host")
  wrapper_path="${AUTOFS_SSH_WRAPPERS_DIR}/ssh-via-${safe_name}"
  desired_content=$(cat <<EOF
#!/bin/sh
exec /usr/bin/ssh -o ProxyJump=root@${jump_host} "\$@"
EOF
)

  ensure_dir "$AUTOFS_SSH_WRAPPERS_DIR"

  if [[ -f $wrapper_path ]]; then
    current_content=$(cat "$wrapper_path")
    if [[ $current_content == "$desired_content" ]]; then
      printf '%s' "$wrapper_path"
      return 0
    fi
  fi

  info "Erzeuge SSHFS-Jump-Wrapper: $wrapper_path"
  printf '%s\n' "$desired_content" > "$wrapper_path"
  chmod 0755 "$wrapper_path"
  AUTOFS_CHANGED=1
  printf '%s' "$wrapper_path"
}

reset_host_autofs_files() {
  local master_map=$1
  local filesystem mapfile

  [[ $AUTOFS_RESET == "1" ]] || return 0

  if [[ -f $master_map ]]; then
    info "Lösche AutoFS-Masterdatei im Reset-Modus: $master_map"
    rm -f "$master_map"
    AUTOFS_CHANGED=1
  fi

  for filesystem in $AUTOFS_FILESYSTEMS; do
    mapfile="${AUTOFS_MAPS_DIR}/${filesystem}/${Name}.map"
    if [[ -f $mapfile ]]; then
      info "Lösche AutoFS-Map im Reset-Modus: $mapfile"
      rm -f "$mapfile"
      AUTOFS_CHANGED=1
    fi
  done
}

create_master_map_if_missing() {
  local mapfile=$1

  if [[ -f $mapfile ]]; then
    info "AutoFS-Masterdatei vorhanden: $mapfile"
    return 0
  fi

  info "Erzeuge AutoFS-Masterdatei: $mapfile"
  {
    printf '# AutoFS mappings for %s\n' "$Name"
    printf '# Von SysMaint erzeugt. Bestehende Dateien werden nicht ueberschrieben.\n'
    printf '#\n'
    local fs
    for fs in $AUTOFS_FILESYSTEMS; do
      printf '/autofs/%-15s /etc/auto.master.d/maps/%-20s uid=0,gid=0,--timeout=60 --ghost\n' \
        "${fs}/${Name}" "${fs}/${Name}.map"
    done
  } > "$mapfile"
  AUTOFS_CHANGED=1
}

create_fs_map_if_missing() {
  local filesystem=$1
  local mapfile=$2
  local sshfs_opts ssh_wrapper

  [[ -f $mapfile ]] && {
    info "AutoFS-Map vorhanden: $mapfile"
    return 0
  }

  info "Erzeuge AutoFS-Map: $mapfile"
  case "$filesystem" in
    loop)
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
        printf '#AutoMountPoint  -fstype=bind :/mount/mountpoint\n'
      } > "$mapfile"
      ;;
    cifs)
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
        printf '#AutoMountPoint  -fstype=cifs,file_mode=0777,iocharset=utf8,dir_mode=0777,username=user,password=pass,vers=2.1,ip=%s ://Server/Share\n' "$IP"
      } > "$mapfile"
      ;;
    nfs)
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
        printf '#AutoMountPoint  -fstype=nfs,rw,retry=0 %s:/mountpoint\n' "$IP"
      } > "$mapfile"
      ;;
    sshfs)
      sshfs_opts='rw,nodev,noatime,allow_other,max_read=65536,users'
      if [[ -n ${JP:-} ]]; then
        ssh_wrapper=$(ensure_sshfs_jump_wrapper "$JP")
        sshfs_opts+=",ssh_command=${ssh_wrapper}"
      fi
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
        if [[ -n ${JP:-} ]]; then
          printf '# Jump host for this target: %s\n' "$JP"
        fi
        printf '#AutoMountPoint  -fstype=fuse,%s :sshfs#remoteuser@%s:/remote/path\n' "$sshfs_opts" "$IP"
        printf 'rootfs           -fstype=fuse,%s :sshfs#root@%s:/\n' "$sshfs_opts" "$IP"
      } > "$mapfile"
      ;;
    *)
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
      } > "$mapfile"
      ;;
  esac
  AUTOFS_CHANGED=1
}

mark_autofs_reload_if_needed() {
  (( AUTOFS_CHANGED == 1 )) || {
    info "Keine neuen AutoFS-Dateien erzeugt, kein AutoFS-Reload nötig"
    return 0
  }

  if [[ -n $AUTOFS_RELOAD_MARKER ]]; then
    printf 'reload\n' > "$AUTOFS_RELOAD_MARKER"
  fi
  info "AutoFS-Reload nach Abschluss des Laufs vorgemerkt"
}

info "Pflege AutoFS-Dateien fuer ${Name}"
ensure_local_packages
ensure_dir "$AUTOFS_BASEDIR"
ensure_dir "$AUTOFS_MAPS_DIR"

master_map="${AUTOFS_BASEDIR}/${Name}.autofs"
reset_host_autofs_files "$master_map"
create_master_map_if_missing "$master_map"

for filesystem in $AUTOFS_FILESYSTEMS; do
  filesystem_dir="${AUTOFS_MAPS_DIR}/${filesystem}"
  ensure_dir "$filesystem_dir"
  create_fs_map_if_missing "$filesystem" "${filesystem_dir}/${Name}.map"
done

mark_autofs_reload_if_needed
