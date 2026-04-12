#!/usr/bin/env bash

export LS_OPTIONS='--color=auto'
eval "$(dircolors -b)"

alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -lah'
alias l='ls $LS_OPTIONS -A'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias jlog='journalctl -xeu'

EDITOR=vi
export EDITOR
