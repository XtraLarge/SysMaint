#!/usr/bin/env bash

alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
alias dlog='function _dlog(){ docker logs -f "$1"; }; _dlog'
alias dexec='function _dexec(){ docker exec -it "$1" "${2:-bash}"; }; _dexec'
alias dimg='docker image ls'
