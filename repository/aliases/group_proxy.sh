#!/usr/bin/env bash

alias apache-config='apache2ctl -t -D DUMP_VHOSTS'
alias apache-reload='systemctl reload apache2'
alias nginx-test='nginx -t'
alias nginx-reload='systemctl reload nginx'
