#!/bin/sh
# Lesende Abfrage der Icinga2-API fuer SysMaint (laeuft auf dem Docker-Host des
# Icinga-Masters, wird per SSH vom Management-Host aufgerufen).
#
#   icinga-query.sh hosts     alle Hosts (name, address, state, vars)
#   icinga-query.sh problems  alle Services mit Status != OK
#
# Nutzt den vorhandenen API-User des Webfrontends. Das Passwort wird im
# Container aus api-users.conf gelesen und per stdin an curl gegeben; es
# verlaesst den Container nicht und taucht in keiner Prozessliste auf.
#
# Umgebung: ICINGA_CONTAINER (Standard icinga2-master),
#           ICINGA_API_USER  (Standard icingaweb)

set -eu
CONTAINER=${ICINGA_CONTAINER:-icinga2-master}
API_USER=${ICINGA_API_USER:-icingaweb}

case ${1:-} in
  hosts)
    BODY='{"attrs":["name","address","state","vars"]}'
    TYPE=hosts
    ;;
  problems)
    BODY='{"filter":"service.state!=0","attrs":["host_name","display_name","state","state_type","acknowledgement","downtime_depth","last_check_result"]}'
    TYPE=services
    ;;
  *)
    echo "Aufruf: $0 hosts|problems" >&2
    exit 2
    ;;
esac

exec docker exec -i -e API_USER="$API_USER" -e BODY="$BODY" -e TYPE="$TYPE" "$CONTAINER" sh -c '
  P=$(sed -n "/ApiUser \"$API_USER\"/,/}/{s/.*password *= *\"\([^\"]*\)\".*/\1/p}" /etc/icinga2/conf.d/api-users.conf | head -1)
  [ -n "$P" ] || { echo "API-User $API_USER nicht gefunden" >&2; exit 3; }
  printf "user = \"%s:%s\"\n" "$API_USER" "$P" | curl -sSk --fail -K - \
    -H "Accept: application/json" -H "X-HTTP-Method-Override: GET" \
    -X POST "https://localhost:5665/v1/objects/$TYPE" -d "$BODY"
'
