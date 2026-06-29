#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
source "$BASE_DIR/lib/common.sh"

# ===========================================================================
# unattended_task.sh
#
# Prueft (AUDIT, Default, read-only) je Host, ob die unattended-upgrades-
# Automatik korrekt aktiv ist, und zieht mit --apply (opt-in) fehlende
# Stuecke idempotent nach. Bereits korrekte Hosts bleiben unangetastet.
#
# Aufruf ueber manage.sh (Flag UP):
#   ./manage.sh UP tasks/unattended_task.sh              # AUDIT (alle UP=1)
#   ./manage.sh UP tasks/unattended_task.sh -- --apply   # APPLY (verAEndernd)
# Bequemer Wrapper: ../run-unattended.sh
# ===========================================================================

# ---------------------------------------------------------------------------
# POLICY-KANON (einzige Wahrheit fuer AUDIT-Vergleich UND APPLY-Schreiben)
#
# Origins-Patterns der unattended-upgrades-Automatik. Die Strings enthalten
# das LITERALE u-u-Makro ${distro_codename} (u-u expandiert es zur Laufzeit,
# NICHT diese Shell) und keinerlei interne Hostnamen/IPs. Hergeleitet vom
# Live-Referenzhost (Debian 13, Policy B = alle Debian-Updates).
#
# >>> POLICY-TOGGLE A <-> B (EIN-Zeilen-Aenderung) <<<
#   Policy B (alle Debian-Updates): NON_SECURITY_ORIGIN-Zeile bleibt aktiv.
#   Policy A (security-only):        NON_SECURITY_ORIGIN-Zeile auskommentieren.
# ---------------------------------------------------------------------------
NON_SECURITY_ORIGIN='origin=Debian,codename=${distro_codename},label=Debian'   # <-- A<->B-Toggle
CANON_ORIGINS=(
  "$NON_SECURITY_ORIGIN"
  'origin=Debian,codename=${distro_codename},label=Debian-Security'
  'origin=Debian,codename=${distro_codename}-security,label=Debian-Security'
)

supports_unattended() { [[ ${BS:-} =~ ^(D|P)$ ]]; }

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    *) err "Unbekannte Option fuer unattended_task.sh: $1"; exit 1 ;;
  esac
done

emit() {
  # $1=STATUS $2=uu $3=periodic $4=20auto $5=origins $6=autorestart $7=timers $8=stamp $9=gaps
  printf 'UU-AUDIT|%s|%s|%s|uu=%s|periodic=%s|20auto=%s|origins=%s|autorestart=%s|timers=%s|stamp=%s|gaps=[%s]\n' \
    "${Name:-?}" "${IP:-?}" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

supports_unattended || {
  warn "${Name:-?}: BS=${BS:-?} nicht Debian/Proxmox - uebersprungen"
  emit SKIP - - - - - - - non-debian
  exit 0
}

build_remote() {
cat <<'EOF_REMOTE'
set -u
MODE="__MODE__"
CANON="$(cat <<'EOF_CANON'
__CANON__
EOF_CANON
)"

dump_origins(){ apt-config dump 2>/dev/null | grep 'Origins-Pattern::' | sed -n 's/.*:: *"\(.*\)";.*/\1/p'; }
cfgval(){ apt-config dump "$1" 2>/dev/null | sed -n 's/^[^"]*"\(.*\)".*/\1/p' | head -n1; }

detect(){
  uu=missing
  dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' && uu=ok
  f20=missing; [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && f20=ok
  periodic=bad
  [ "$(cfgval APT::Periodic::Update-Package-Lists)" = "1" ] && [ "$(cfgval APT::Periodic::Unattended-Upgrade)" = "1" ] && periodic=ok
  eff="$(dump_origins)"; omiss=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s\n' "$eff" | grep -qxF "$c" || omiss=$((omiss+1))
  done <<EOF_L
$CANON
EOF_L
  origins=ok; [ "$omiss" -gt 0 ] && origins=drift
  arv="$(apt-config dump 2>/dev/null | grep 'utomatic-Re' | sed -n 's/.*"\(.*\)".*/\1/p' | head -n1)"
  autorestart=ok; case "$arv" in [Tt]rue|1) autorestart=on ;; esac
  te=bad; ta=bad
  systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 && te=ok
  systemctl is-active  apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 && ta=ok
  stampf=/var/lib/apt/periodic/unattended-upgrades-stamp
  if [ -f "$stampf" ]; then
    now=$(date +%s); m=$(stat -c %Y "$stampf" 2>/dev/null || echo 0); stamp="$(( (now-m)/86400 ))d"
  else
    stamp=never
  fi
}

gen_drop(){
  printf '%s\n' "// Verwaltet von SysMaint unattended_task.sh - nicht von Hand editieren." \
                "Unattended-Upgrade::Origins-Pattern {"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '        "%s";\n' "$c"
  done <<EOF_D
$CANON
EOF_D
  printf '};\n'
}

detect
if [ "$MODE" = "apply" ]; then
  changed=""
  export DEBIAN_FRONTEND=noninteractive
  if [ "$uu" != ok ]; then
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y -qq -o DPkg::Options::=--force-confold unattended-upgrades >/dev/null 2>&1; then
      changed="${changed}uu "
    else
      echo "UUERR install-unattended-upgrades-failed"
    fi
  fi
  want20="$(printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";')"
  if [ "$(cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)" != "$want20" ]; then
    printf '%s\n' "$want20" > /etc/apt/apt.conf.d/20auto-upgrades && changed="${changed}20auto "
  fi
  # Origins-Drop-in NUR schreiben, wenn der Kanon noch nicht vollstaendig wirkt
  # (echte Idempotenz: bereits korrekte Hosts bleiben voellig unangetastet).
  # Hinweis: fuegt fehlende Kanon-Origins additiv hinzu, entfernt keine Extras;
  # ein Policy-Rueckbau B->A erfordert manuelles Entfernen des Drop-ins.
  if [ "$origins" != ok ]; then
    dropf=/etc/apt/apt.conf.d/52sysmaint-unattended-origins.conf
    wantdrop="$(gen_drop)"
    if [ "$(cat "$dropf" 2>/dev/null)" != "$wantdrop" ]; then
      printf '%s\n' "$wantdrop" > "$dropf" && changed="${changed}origins "
    fi
  fi
  if ! { systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 \
       && systemctl is-active  apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1; }; then
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 && changed="${changed}timers "
  fi
  unattended-upgrade --dry-run -d >/dev/null 2>&1 && dry=ok || dry=fail
  detect
  echo "UUAPPLY changed=[${changed:-none}] dry=${dry}"
fi
echo "UUDATA uu=${uu} periodic=${periodic} f20=${f20} origins=${origins} omiss=${omiss} autorestart=${autorestart} tenab=${te} tact=${ta} stamp=${stamp}"
EOF_REMOTE
}

remote_run() {
  local mode="$1" canon_block tmpl
  canon_block="$(printf '%s\n' "${CANON_ORIGINS[@]}")"
  tmpl="$(build_remote)"
  tmpl="${tmpl//__MODE__/$mode}"
  tmpl="${tmpl//__CANON__/$canon_block}"
  run_ssh_bash "$tmpl"
}

remove_known_host
mode=audit; [[ $APPLY == 1 ]] && mode=apply
info "${Name}: unattended-upgrades ${mode}"

if out="$(remote_run "$mode" 2>/dev/null)"; then
  data="$(printf '%s\n' "$out" | grep '^UUDATA ' | head -n1)"
  applyline="$(printf '%s\n' "$out" | grep '^UUAPPLY ' | head -n1 || true)"
  fields=" ${data#UUDATA }"
  val(){ local x; case "$fields" in *" $1="*) x="${fields##* $1=}"; printf '%s' "${x%% *}" ;; esac; }
  gaps=""
  [[ "$(val uu)"          == ok ]] || gaps="${gaps}uu "
  [[ "$(val periodic)"    == ok ]] || gaps="${gaps}periodic "
  [[ "$(val f20)"         == ok ]] || gaps="${gaps}20auto "
  [[ "$(val origins)"     == ok ]] || gaps="${gaps}origins "
  [[ "$(val autorestart)" == ok ]] || gaps="${gaps}autorestart-on "
  [[ "$(val tenab)"       == ok ]] || gaps="${gaps}timer-enable "
  [[ "$(val tact)"        == ok ]] || gaps="${gaps}timer-active "
  status=OK; [[ -n $gaps ]] && status=GAP
  emit "$status" "$(val uu)" "$(val periodic)" "$(val f20)" "$(val origins)/miss$(val omiss)" \
       "$(val autorestart)" "$(val tenab)/$(val tact)" "$(val stamp)" "${gaps:-none}"
  [[ -n $applyline ]] && printf 'UU-APPLY|%s|%s|%s\n' "${Name}" "${IP}" "${applyline#UUAPPLY }"
  printf '%s\n' "$out" | grep '^UUERR ' && warn "${Name}: Apply-Fehler (siehe UUERR)" || true
  exit 0
else
  warn "${Name}: nicht erreichbar oder Audit fehlgeschlagen"
  emit ERROR - - - - - - - unreachable
  [[ $APPLY == 1 ]] && exit 1 || exit 0
fi
