#!/usr/bin/env bash

set -o pipefail
shopt -s extglob

: "${DEBUG:=}"
: "${SSH_USER:=root}"
: "${SSH_OPTS_BASE:=-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4}"
# Hartes Gesamt-Timeout (Bordmittel timeout) um jeden SSH/SCP-Aufruf.
# ServerAlive erkennt tote ETABLIERTE Sessions (~60s); der timeout-Deckel
# faengt zusaetzlich Banner-Exchange-Haenger ab, wo ServerAlive NICHT greift.
# Werte in Sekunden; 0 oder leer deaktiviert den jeweiligen Deckel.
: "${SSH_CMD_TIMEOUT:=1800}"
: "${SSH_PRECHECK_TIMEOUT:=60}"
: "${SYSTEMS_FILE:=./.Systems.sh}"

TEXT_RESET=$'\e[0m'
TEXT_GREEN=$'\e[1;32m'
TEXT_YELLOW=$'\e[0;33m'
TEXT_RED=$'\e[0;31m'
TEXT_RED_B=$'\e[1;31m'
TEXT_BLUE=$'\e[1;36m'

log()  { printf '[%s] %s
' "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
err()  { log ERROR "$*" >&2; }
dbg()  {
  if [[ -n ${DEBUG:-} ]]; then
    log DBG "$*"
  fi
  return 0
}

print_host_banner() {
  local name=${1:-unknown}
  printf '
%s>>> %s%s
' "$TEXT_BLUE" "$name" "$TEXT_RESET"
}

require_file() {
  local file=$1
  [[ -r $file ]] || {
    err "Datei nicht lesbar: $file"
    return 1
  }
}

build_ssh_target() {
  printf '%s@%s' "$SSH_USER" "$IP"
}

build_ssh_base_opts() {
  local opts=()
  # IFS explizit auf Standard-Whitespace setzen: .Systems.sh setzt IFS=$'\n' global,
  # was das Space-Splitting von SSH_OPTS_BASE unterbricht (gesamter String würde ein
  # Element → SSH-Fehler "keyword batchmode extra arguments at end of line").
  local IFS=$' \t\n'
  if [[ -n ${SSH_OPTS_BASE:-} ]]; then
    # bewusstes Word-Splitting für klassische SSH -o Optionen aus einer String-Variable
    # shellcheck disable=SC2206
    opts=( ${SSH_OPTS_BASE} )
  fi
  printf '%s\0' "${opts[@]}"
}

# Fuehrt ein Kommando unter hartem Gesamt-Timeout aus (Bordmittel timeout).
# Nutzung: with_timeout <sekunden> <cmd...>. Leer/0 oder fehlendes timeout
# => Kommando laeuft ohne Deckel (rueckwaertskompatibel).
with_timeout() {
  local secs=${1-}
  shift || return 0
  if [[ -n $secs && $secs != 0 ]] && command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10 "$secs" "$@"
  else
    "$@"
  fi
}

run_ssh() {
  local target
  local -a ssh_opts=()
  target=$(build_ssh_target)

  while IFS= read -r -d '' opt; do
    ssh_opts+=("$opt")
  done < <(build_ssh_base_opts)

  if [[ -n ${JP:-} ]]; then
    ssh_opts+=(-J "${SSH_USER}@${JP}")
  fi

  with_timeout "$SSH_CMD_TIMEOUT" ssh "${ssh_opts[@]}" "$target" "$@"
}

run_ssh_bash() {
  local remote_script=$1
  local target
  local -a ssh_opts=()
  target=$(build_ssh_target)

  while IFS= read -r -d '' opt; do
    ssh_opts+=("$opt")
  done < <(build_ssh_base_opts)

  if [[ -n ${JP:-} ]]; then
    ssh_opts+=(-J "${SSH_USER}@${JP}")
  fi

  if ! with_timeout "$SSH_PRECHECK_TIMEOUT" ssh "${ssh_opts[@]}" "$target" 'sh -c '"'"'command -v bash >/dev/null 2>&1'"'"''; then
    err "${Name:-$IP}: bash ist auf dem Zielsystem nicht verfügbar oder der Vorabcheck ist fehlgeschlagen"
    return 1
  fi

  with_timeout "$SSH_CMD_TIMEOUT" ssh "${ssh_opts[@]}" "$target" bash -s -- <<EOF_REMOTE
$remote_script
EOF_REMOTE
}

# ---------------------------------------------------------------------------
# ssh_reachable: leichtgewichtiger Erreichbarkeits-Probe (nur SSH-Connect, kein
# Remote-Task). Fuehrt lediglich 'true' auf dem Ziel aus. Return 0 = SSH-
# Verbindung steht (Host ERREICHBAR), sonst nicht erreichbar. Dient dazu, im
# Fehlerfall echte Unerreichbarkeit von "erreichbar, aber Task fehlgeschlagen"
# (z.B. bash/apt fehlt, Remote-Skript-Fehler) zu unterscheiden. Nutzt bewusst
# 'true' (POSIX) statt eines Interpreter-Checks, damit fehlendes bash NICHT
# faelschlich als unerreichbar gewertet wird (#1837).
# ---------------------------------------------------------------------------
ssh_reachable() {
  local target
  local -a ssh_opts=()
  target=$(build_ssh_target)

  while IFS= read -r -d '' opt; do
    ssh_opts+=("$opt")
  done < <(build_ssh_base_opts)

  if [[ -n ${JP:-} ]]; then
    ssh_opts+=(-J "${SSH_USER}@${JP}")
  fi

  with_timeout "$SSH_PRECHECK_TIMEOUT" ssh "${ssh_opts[@]}" "$target" true >/dev/null 2>&1
}

run_ssh_sh() {
  local remote_script=$1
  local target
  local -a ssh_opts=()
  target=$(build_ssh_target)

  while IFS= read -r -d '' opt; do
    ssh_opts+=("$opt")
  done < <(build_ssh_base_opts)

  if [[ -n ${JP:-} ]]; then
    ssh_opts+=(-J "${SSH_USER}@${JP}")
  fi

  if ! with_timeout "$SSH_PRECHECK_TIMEOUT" ssh "${ssh_opts[@]}" "$target" 'sh -c '"'"'command -v sh >/dev/null 2>&1'"'"''; then
    err "${Name:-$IP}: sh ist auf dem Zielsystem nicht verfügbar oder der Vorabcheck ist fehlgeschlagen"
    return 1
  fi

  with_timeout "$SSH_CMD_TIMEOUT" ssh "${ssh_opts[@]}" "$target" sh -s -- <<EOF_REMOTE
$remote_script
EOF_REMOTE
}

run_ssh_with_stdin() {
  local remote_script=$1
  shift
  local target
  local -a ssh_opts=()
  target=$(build_ssh_target)

  while IFS= read -r -d '' opt; do
    ssh_opts+=("$opt")
  done < <(build_ssh_base_opts)

  if [[ -n ${JP:-} ]]; then
    ssh_opts+=(-J "${SSH_USER}@${JP}")
  fi

  with_timeout "$SSH_CMD_TIMEOUT" ssh "${ssh_opts[@]}" "$target" bash -c "$(printf '%q' "$remote_script")" -- "$@"
}

run_scp() {
  local source_path=$1
  local target_path=$2
  local -a scp_opts=(-B -q)

  if [[ -n ${JP:-} ]]; then
    scp_opts+=(-o "ProxyJump=${SSH_USER}@${JP}")
  fi

  with_timeout "$SSH_CMD_TIMEOUT" scp "${scp_opts[@]}" "$source_path" "$(build_ssh_target):$target_path"
}

remove_known_host() {
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${IP}" >/dev/null 2>&1 || true
}
