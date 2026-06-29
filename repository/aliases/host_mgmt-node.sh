#!/usr/bin/env bash

alias sysmaint-status='cd /root/SysMaint && ./run-status.sh'
alias sysmaint-log='cd /root/SysMaint && less logs/last_run.log'
alias sr='screen -dr "$(screen -ls | grep -oP "^\s+\K[0-9]+\.\S+" | fzf --height 40% --reverse --prompt "screen> ")"'
