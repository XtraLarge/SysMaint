#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

AUTOFS_BASEDIR=${AUTOFS_BASEDIR:-/etc/auto.master.d}
AUTOFS_MAPS_DIR=${AUTOFS_MAPS_DIR:-$AUTOFS_BASEDIR/maps}
AUTOFS_FILESYSTEMS=${AUTOFS_FILESYSTEMS:-loop sshfs cifs nfs}
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
    return 0
  fi

  warn "Kein unterstützter Paketmanager für AutoFS-Paketprüfung gefunden"
}

ensure_dir() {
  local dir=$1
  [[ -d $dir ]] || mkdir -p "$dir"
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
}

create_fs_map_if_missing() {
  local filesystem=$1
  local mapfile=$2

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
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
        printf '#AutoMountPoint  -fstype=fuse,rw,nodev,noatime,allow_other,max_read=65536,users :sshfs#remoteuser@%s:/remote/path\n' "$IP"
        printf 'rootfs           -fstype=fuse,rw,nodev,noatime,allow_other,max_read=65536,users :sshfs#root@%s:/\n' "$IP"
      } > "$mapfile"
      ;;
    *)
      {
        printf '# AutoFS mountpoints for %s\n' "$Name"
        printf '#\n'
      } > "$mapfile"
      ;;
  esac
}

info "Pflege AutoFS-Dateien fuer ${Name}"
ensure_local_packages
ensure_dir "$AUTOFS_BASEDIR"
ensure_dir "$AUTOFS_MAPS_DIR"

master_map="${AUTOFS_BASEDIR}/${Name}.autofs"
create_master_map_if_missing "$master_map"

for filesystem in $AUTOFS_FILESYSTEMS; do
  filesystem_dir="${AUTOFS_MAPS_DIR}/${filesystem}"
  ensure_dir "$filesystem_dir"
  create_fs_map_if_missing "$filesystem" "${filesystem_dir}/${Name}.map"
done
