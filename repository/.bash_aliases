#!/usr/bin/env bash

case "${TERM:-}" in
  xterm*|screen*|tmux*)
    if command -v figlet >/dev/null 2>&1; then
      figlet -w "$(tput cols 2>/dev/null || printf '80')" "${HOSTNAME}"
    fi
    ;;
esac

export LS_OPTIONS='--color=auto'
eval "$(dircolors -b)"

alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -lah'
alias l='ls $LS_OPTIONS -A'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
alias dlog='function _dlog(){ docker logs -f "$1"; }; _dlog'
alias jlog='journalctl -xeu'

EDITOR=vi
export EDITOR
