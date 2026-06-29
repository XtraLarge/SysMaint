#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TASK="$BASE_DIR/tasks/unattended_task.sh"

usage() {
  cat <<'EOF_USAGE'
Verwendung:
  ./run-unattended.sh [audit] [--jobs N]                  # AUDIT (read-only, Default)
  ./run-unattended.sh audit only HOST [HOST...] [--jobs N]
  ./run-unattended.sh apply [--jobs N]                    # APPLY (opt-in, veraendernd)
  ./run-unattended.sh apply only HOST [HOST...] [--jobs N]
  ./run-unattended.sh --help

AUDIT prueft flottenweit (Hosts mit Flag UP=1, BS=D/P), ob unattended-upgrades
korrekt aktiv ist, und gibt eine kompakte Statustabelle aus (read-only).
APPLY zieht fehlende Stuecke idempotent nach; bereits korrekte Hosts bleiben
unveraendert. HOST = exakte IP/DNS aus .Systems.sh.

ACHTUNG: APPLY aktiviert Timer/Autostart + selbsttaetiges Patchen (dauerhafte
Wirkung). Massen-Apply (mehr als ein Test-Host) nur nach Freigabe ausrollen.
EOF_USAGE
}

mode=audit
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  audit) shift ;;
  apply) mode=apply; shift ;;
  ""|only|--jobs) ;;
  *) echo "Unbekannter Modus: $1 (audit|apply)" >&2; usage >&2; exit 1 ;;
esac

scope=full
only_hosts=()
if [[ "${1:-}" == only ]]; then
  shift
  scope=only
  while [[ $# -gt 0 && "$1" != --* ]]; do only_hosts+=("$1"); shift; done
  [[ ${#only_hosts[@]} -gt 0 ]] || { echo "only benoetigt mindestens einen HOST" >&2; exit 1; }
fi
passthru=("$@")

manage_opts=()
[[ $scope == only ]] && manage_opts+=(--only "${only_hosts[@]}")
[[ ${#passthru[@]} -gt 0 ]] && manage_opts+=("${passthru[@]}")
task_args=()
[[ $mode == apply ]] && task_args=(-- --apply)

run_log="$(mktemp "${TMPDIR:-/tmp}/sysmaint-uu.XXXXXX")"
trap 'rm -f "$run_log"' EXIT

set +e
"$BASE_DIR/manage.sh" UP "$TASK" "${manage_opts[@]}" "${task_args[@]}" | tee "$run_log"
rc=${PIPESTATUS[0]}
set -e

echo
echo "===== unattended-upgrades ${mode} - Uebersicht ====="
{
  printf 'STATUS|HOST|IP|u-u|periodic|20auto|origins|autorestart|timers|stamp|luecken\n'
  grep -ho 'UU-AUDIT|.*' "$run_log" | sort -t'|' -k4,4 -k2,2 \
    | while IFS='|' read -r _ name ip status f_uu f_p f_20 f_o f_ar f_tmr f_st f_g; do
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
          "$status" "$name" "$ip" "${f_uu#*=}" "${f_p#*=}" "${f_20#*=}" "${f_o#*=}" \
          "${f_ar#*=}" "${f_tmr#*=}" "${f_st#*=}" "${f_g#*=}"
      done
} | column -t -s '|'

ok=$(grep -hc 'UU-AUDIT|[^|]*|[^|]*|OK|'     "$run_log" || true)
gap=$(grep -hc 'UU-AUDIT|[^|]*|[^|]*|GAP|'    "$run_log" || true)
er=$(grep -hc 'UU-AUDIT|[^|]*|[^|]*|ERROR|'   "$run_log" || true)
sk=$(grep -hc 'UU-AUDIT|[^|]*|[^|]*|SKIP|'    "$run_log" || true)
echo
printf 'Summe: OK=%s GAP=%s ERROR=%s SKIP=%s\n' "${ok:-0}" "${gap:-0}" "${er:-0}" "${sk:-0}"

exit "$rc"
