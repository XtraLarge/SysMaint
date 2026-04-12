#!/usr/bin/env bash
# Example system inventory for SysMaint.
# Replace the sample hosts with your own environment before productive use.
#
# Format:
# - Header lines start with ! and define the field names.
# - Records use # as a field separator.
# - Comment lines start with #.
#
# Standard fields:
# Typ, ID, Name, IP, BS, UP, FR, BK, KY, RS, SH, AF, JP, SG, Host, RB

# Optional runtime configuration
# Default bounded parallelism
DEFAULT_JOBS=${DEFAULT_JOBS:-8}
DEFAULT_REBOOT_DELAY=${DEFAULT_REBOOT_DELAY:-1}
LOCAL_REBOOT_DELAY=${LOCAL_REBOOT_DELAY:-5}

# Managed SSH keys:
# - place the normal managed public keys in KEYS_MANAGED_DIR
# - keep the backup key separate in BACKUP_KEY_FILE
KEYS_MANAGED_DIR=${KEYS_MANAGED_DIR:-/etc/sysmaint/keys/managed}
BACKUP_KEY_FILE=${BACKUP_KEY_FILE:-/etc/sysmaint/keys/backup.pub}

# Shell baseline packages per operating system family
SHELL_PACKAGES_D=${SHELL_PACKAGES_D:-"bash-completion vim less"}
SHELL_PACKAGES_U=${SHELL_PACKAGES_U:-"$SHELL_PACKAGES_D"}
SHELL_PACKAGES_S=${SHELL_PACKAGES_S:-"vim less"}
SHELL_PACKAGES_B=${SHELL_PACKAGES_B:-""}
SHELL_PACKAGES_X=${SHELL_PACKAGES_X:-""}

# AutoFS packages on the management host
AUTOFS_PACKAGES_D=${AUTOFS_PACKAGES_D:-"autofs cifs-utils nfs-common sshfs"}
AUTOFS_PACKAGES_U=${AUTOFS_PACKAGES_U:-"$AUTOFS_PACKAGES_D"}
AUTOFS_PACKAGES_S=${AUTOFS_PACKAGES_S:-"autofs cifs-utils nfs-client sshfs"}

# Remote syslog target
RSYSLOG_TARGET_HOST=${RSYSLOG_TARGET_HOST:-syslog.home.arpa}
RSYSLOG_TARGET_PORT=${RSYSLOG_TARGET_PORT:-1514}
RSYSLOG_TARGET_PROTOCOL=${RSYSLOG_TARGET_PROTOCOL:-udp}

IFS=$'\n'
mapfile -t HOSTNAMES <<'SYSTEMS_EOF'
!Typ !ID  !Name              !IP                    !BS !UP !FR !BK !KY !RS !SH !AF !JP !SG          !Host       !RB
# Typ  P=Physical, V=Virtual, N=Network
# ID   Freely chosen inventory ID
# Name Display name
# IP   Target address or DNS name
# BS   D=Debian, U=Univention, S=SUSE, X=Other
# UP   Update       1=true, 0=false
# FR   Force-Reboot 1=true, 0=false
# BK   Backup key   1=true, 0=false
# KY   SSH keys     1=true, 0=false
# RS   RSyslog      1=true, 0=false
# SH   Shell kit    1=true, 0=false
# AF   AutoFS       1=true, 0=false
# JP   Jump host    host or IP, empty = direct connection
# SG   Shell groups, comma-separated. Shell deployment order is base_*, then group_*, then host_*
# Host Optionaler Host/Hypervisor für Reboot-Abhängigkeiten
# RB   Optionaler Reboot-Delay in Minuten
#
# Example environment
###############
#Typ !ID  !Name              !IP                    !BS !UP !FR !BK !KY !RS !SH !AF !JP                     !SG          !Host       !RB
V    #101 #mgmt-node         #192.0.2.10            #D  #1  #1  #1  #1  #1  #1  #1  #                      #            #           #
V    #102 #docker-node-a     #192.0.2.20            #D  #1  #1  #1  #1  #1  #1  #1  #                      #docker      #fileserver #
V    #103 #docker-node-b     #192.0.2.21            #D  #1  #1  #1  #1  #1  #1  #1  #                      #docker      #fileserver #
P    #201 #fileserver        #198.51.100.10         #D  #1  #1  #1  #1  #1  #1  #1  #                      #hardware    #           #
V    #301 #branch-app        #app-01.example.net    #U  #1  #1  #0  #1  #1  #1  #0  #jump-gateway.example.net #proxy      #           #
N    #401 #edge-router       #router-01.example.net #X  #0  #0  #0  #0  #0  #0  #1  #                      #            #           #
SYSTEMS_EOF

: "${DEBUG:=}"
declare -ag HEAD=()

systems_trim() {
  local value=${1-}
  value=${value//$'\r'/}
  value=${value##+([[:space:]])}
  value=${value%%+([[:space:]])}
  printf '%s' "$value"
}

header() {
  local raw=${LINE-}
  raw=${raw#!}
  IFS='!' read -r -a HEAD <<< "$raw"
  local i
  for i in "${!HEAD[@]}"; do
    HEAD[$i]="$(printf '%s' "${HEAD[$i]}" | tr -d '[:space:]')"
  done
}

element() {
  local i value
  local -a ELEM=()

  unset Typ ID Name IP BS UP FR BK KY RS SH AF JP SG Host RB
  IFS='#' read -r -a ELEM <<< "$LINE"

  for i in "${!HEAD[@]}"; do
    value="${ELEM[$i]-}"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"

    if [[ ${HEAD[$i]-} == "IP" && -z $value ]]; then
      value="${Name-}"
    fi

  printf -v "${HEAD[$i]}" '%s' "$value"
  done

  : "${JP:=}"
  : "${SG:=}"
  : "${Host:=}"
  : "${RB:=}"
}

systems_init() {
  local line
  for line in "${HOSTNAMES[@]}"; do
    if [[ $line == \!* ]]; then
      LINE=$line
      header
      return 0
    fi
  done
  return 1
}

systems_init || {
  echo "No valid header line found in .Systems.sh." >&2
  return 1 2>/dev/null || exit 1
}
