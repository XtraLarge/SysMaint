#!/usr/bin/env python3
"""Nachkontrolle nach dem Wochenlauf (laeuft einige Stunden spaeter, nach den Reboots).

Prueft fuer alle laufenden Systeme des Inventars:
  1. Erreichbarkeit per SSH, erfolgter Reboot, ausstehender Neustart, SSH-Key-Block
  2. Logs: kommen frische Syslog-Daten in Loki an (beweist die RSyslog-Weiterleitung),
     und welche kritischen Meldungen gab es seit Beginn des Wochenlaufs
  3. Monitoring: offene, unquittierte Icinga-Probleme (harter Zustand)
  4. Backup-Abdeckung (nur pruefen, nichts aendern):
     - jeder laufende Gast steckt in einem aktiven vzdump/PBS-Job
     - Platten mit backup=0 gehoeren zu einem Host in BackupPC (sonst ungesichert)
     - physische Systeme stehen in BackupPC
     - jeder BackupPC-Host hat im Monitoring backuppc_hostname (Frische wird ueberwacht)
     - Daten nicht redundant: eine BackupPC-Freigabe, die nicht auf einer aus PBS
       ausgenommenen Datenplatte (backup=0) liegt, ist zusaetzlich im PBS-Image
       enthalten (Grundsatz: System als Image, Daten genau einmal)

Bekannte Ausnahmen kommen ueber EXCEPTIONS_CMD (Quelle: Ausnahmen-Seite).

Umgebung (aus /etc/sysmaint/config.sh, exportiert von run-verify.sh):
  LOKI_URL, ICINGA_QUERY_CMD, BACKUPPC_SHARES_CMD (Zeilen HOST|SHARE, bevorzugt)
  oder BACKUPPC_HOSTS_CMD (nur Hostliste), EXCEPTIONS_CMD,
  VERIFY_LOG_WINDOW_MIN (Standard 60), VERIFY_JOBS (Standard 8)

Schreibt <lauf>/verify.txt (erste Zeile = Mail-Betreff) und logs/last_verify.status.
Exit-Code: 0 = OK, 1 = Hinweise, 2 = Fehler
"""

import json
import os
import shlex
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sysmaint_common import (LOG_DIR, find_exception, latest_run_dir, load_exceptions,  # noqa: E402
                             load_inventory, norm, read_report, read_status, sh, write_status)

SSH_OPTS = "-n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
WINDOW_MIN = int(os.environ.get("VERIFY_LOG_WINDOW_MIN", "60"))
JOBS = int(os.environ.get("VERIFY_JOBS", "8"))

errors, warnings, infos = [], [], []


def ssh_cmd(host, remote, timeout=60):
    jp = f"-J root@{host['jp']} " if host.get("jp") else ""
    return sh(f"timeout {timeout} ssh {SSH_OPTS} {jp}root@{host['ip']} {shlex.quote(remote)}", timeout=timeout + 5)


def excepted(names, check):
    return find_exception(EXCEPTIONS, names, check)


# --------------------------------------------------------------------------
# 1. Host-Pruefung per SSH
# --------------------------------------------------------------------------
HOST_PROBE = (
    "hostname -s; "
    "date -d \"$(uptime -s)\" +%s; "
    "if [ -f /var/run/reboot-required ]; then echo RR; else echo NORR; fi; "
    "grep -c 'BEGIN SYSMAINT MANAGED KEYS' /root/.ssh/authorized_keys 2>/dev/null || echo 0"
)


def probe(host):
    rc, out, err = ssh_cmd(host, HOST_PROBE, timeout=45)
    lines = out.split()
    if rc != 0 or len(lines) < 4:
        return host, None, (err.strip().splitlines() or [f"rc={rc}"])[-1]
    return host, {"hostname": lines[0], "boot": int(lines[1]), "rr": lines[2] == "RR",
                  "keys": int(lines[3])}, None


def check_hosts(targets, run_start, expect_reboot):
    facts = {}
    with ThreadPoolExecutor(max_workers=JOBS) as pool:
        for host, data, err in pool.map(probe, targets):
            names = {host["name"], host["ip"]}
            if data is None:
                if excepted(names, "*"):
                    infos.append(f"{host['name']}: nicht erreichbar - bekannte Ausnahme")
                else:
                    errors.append(f"{host['name']} ({host['ip']}): nach dem Lauf nicht erreichbar ({err[:120]})")
                continue
            facts[host["name"]] = data
            if norm(host["name"]) in expect_reboot and data["boot"] < run_start:
                warnings.append(f"{host['name']}: Reboot war geplant, ist aber nicht erfolgt "
                                f"(laeuft seit {datetime.fromtimestamp(data['boot']):%d.%m. %H:%M})")
            if data["rr"]:
                warnings.append(f"{host['name']}: meldet weiterhin 'Neustart erforderlich'")
            if host.get("ky") == "1" and data["keys"] == 0 and not excepted(names, "keys"):
                errors.append(f"{host['name']}: SysMaint-Key-Block fehlt in authorized_keys")
    return facts


# --------------------------------------------------------------------------
# 2. Logs in Loki
# --------------------------------------------------------------------------
def loki_query(base, query):
    url = f"{base.rstrip('/')}/loki/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.load(resp)
    return {r["metric"].get("host", ""): float(r["value"][1]) for r in data["data"]["result"]}


def check_logs(targets, facts, run_start):
    base = os.environ.get("LOKI_URL", "").strip()
    if not base:
        infos.append("Log-Pruefung uebersprungen (LOKI_URL nicht gesetzt)")
        return
    try:
        fresh = loki_query(base, f'sum by (host) (count_over_time({{job="syslog"}}[{WINDOW_MIN}m]))')
        since = max(60, int(time.time() - run_start))
        crit = loki_query(base, 'sum by (host) (count_over_time({job="syslog", '
                                f'severity=~"emergency|alert|critical"}}[{since}s]))')
        errs = loki_query(base, f'sum by (host) (count_over_time({{job="syslog", severity="error"}}[{since}s]))')
    except Exception as exc:  # noqa: BLE001 - Bericht statt Absturz
        warnings.append(f"Loki nicht abfragbar: {exc}")
        return
    fresh_n = {norm(h) for h in fresh}
    label_of = {}
    for t in targets:
        if t.get("rs") != "1":
            continue
        cands = {norm(t["name"])}
        if t["name"] in facts:
            cands.add(norm(facts[t["name"]]["hostname"]))
        hit = cands & fresh_n
        if hit:
            label_of[t["name"]] = hit.pop()
        elif not excepted({t["name"], t["ip"]}, "logs"):
            errors.append(f"{t['name']}: seit {WINDOW_MIN} min keine Logs in Loki (RSyslog-Weiterleitung pruefen)")
    for label, n in sorted(crit.items(), key=lambda x: -x[1]):
        warnings.append(f"Logs {label}: {int(n)} kritische Meldung(en) seit Laufbeginn")
    top = sorted(errs.items(), key=lambda x: -x[1])[:10]
    if top:
        infos.append("Fehlermeldungen seit Laufbeginn (Top 10): "
                     + ", ".join(f"{h}={int(n)}" for h, n in top))


# --------------------------------------------------------------------------
# 3. Icinga
# --------------------------------------------------------------------------
def icinga(kind):
    cmd = os.environ.get("ICINGA_QUERY_CMD", "").strip()
    if not cmd:
        return None
    rc, out, err = sh(f"{cmd} {kind}", timeout=90)
    if rc != 0:
        raise RuntimeError(err.strip()[:200] or f"rc={rc}")
    return json.loads(out).get("results", [])


def check_icinga():
    try:
        probs = icinga("problems")
    except Exception as exc:  # noqa: BLE001
        warnings.append(f"Icinga nicht abfragbar: {exc}")
        return None
    if probs is None:
        infos.append("Icinga-Pruefung uebersprungen (ICINGA_QUERY_CMD nicht gesetzt)")
        return None
    state_txt = {1: "WARNING", 2: "CRITICAL", 3: "UNKNOWN"}
    for p in probs:
        a = p.get("attrs", {})
        if a.get("state_type") != 1 or a.get("acknowledgement") or a.get("downtime_depth"):
            continue
        out = ((a.get("last_check_result") or {}).get("output") or "").splitlines()
        warnings.append(f"Icinga {a.get('host_name')} / {a.get('display_name')}: "
                        f"{state_txt.get(int(a.get('state', 3)), '?')} - {(out[0] if out else '')[:140]}")
    try:
        return icinga("hosts")
    except Exception as exc:  # noqa: BLE001
        warnings.append(f"Icinga-Hosts nicht abfragbar: {exc}")
        return None


# --------------------------------------------------------------------------
# 4. Backup-Abdeckung
# --------------------------------------------------------------------------
PX_PROBE = r"""
echo "NODE|$(hostname)"
for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  c=$(pct config "$id" 2>/dev/null); st=$(pct status "$id" | awk '{print $2}')
  n=$(printf '%s\n' "$c" | awk '/^hostname:/{print $2; exit}')
  d=$(printf '%s\n' "$c" | grep -E '^mp[0-9]+:' | grep 'backup=0' | sed -E 's/^(mp[0-9]+):.*[ ,]mp=([^,]+).*/\1=\2/' | paste -sd, -)
  echo "GUEST|$id|lxc|$n|$st|$d"
done
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  c=$(qm config "$id" 2>/dev/null); st=$(qm status "$id" | awk '{print $2}')
  n=$(printf '%s\n' "$c" | awk '/^name:/{print $2; exit}')
  d=$(printf '%s\n' "$c" | grep -E '^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:' | grep 'backup=0' | cut -d: -f1 | paste -sd, -)
  echo "GUEST|$id|qemu|$n|$st|$d"
done
echo "JOBS"
cat /etc/pve/jobs.cfg 2>/dev/null
"""


def parse_jobs(text):
    jobs, cur = [], None
    for ln in text.splitlines():
        if ln.startswith("vzdump:"):
            cur = {"id": ln.split(":", 1)[1].strip(), "enabled": "1"}
            jobs.append(cur)
        elif cur is not None and ln.startswith(("\t", " ")) and ln.strip():
            k, _, v = ln.strip().partition(" ")
            cur[k] = v.strip()
        elif not ln.strip():
            cur = None
    return [j for j in jobs if j.get("enabled", "1") == "1"]


def covered_by_job(jobs, vmid, node):
    for j in jobs:
        if j.get("node") and j["node"] != node:
            continue
        if vmid in [x.strip() for x in j.get("vmid", "").split(",") if x.strip()]:
            return j["id"]
        if j.get("all") == "1" and vmid not in [x.strip() for x in j.get("exclude", "").split(",")]:
            return j["id"]
        if j.get("pool"):
            return f"{j['id']} (Pool {j['pool']}, nicht aufgeloest)"
    return None


def load_backuppc():
    """BackupPC-Hosts und ihre Freigaben. Rueckgabe (verfuegbar, {norm: name}, {norm: [shares]|None})."""
    shares_cmd = os.environ.get("BACKUPPC_SHARES_CMD", "").strip()
    hosts_cmd = os.environ.get("BACKUPPC_HOSTS_CMD", "").strip()
    names, shares = {}, {}
    if shares_cmd:
        rc, out, err = sh(shares_cmd, timeout=90)
        if rc != 0:
            warnings.append(f"BackupPC-Freigaben nicht abrufbar: {err.strip()[:150]}")
            return False, names, shares
        for ln in out.splitlines():
            host, sep, share = ln.strip().partition("|")
            if not sep or not host or host.startswith("_"):
                continue
            names[norm(host)] = host
            share = share.strip()
            share = share.rstrip("/") or "/"
            shares.setdefault(norm(host), []).append(share)
        return True, names, shares
    if hosts_cmd:
        rc, out, err = sh(hosts_cmd, timeout=60)
        if rc != 0:
            warnings.append(f"BackupPC-Hostliste nicht abrufbar: {err.strip()[:150]}")
            return False, names, shares
        for ln in out.splitlines():
            h = ln.strip()
            if h and not h.startswith("_"):
                names[norm(h)] = h
                shares[norm(h)] = None
        return True, names, shares
    infos.append("BackupPC-Pruefung uebersprungen (BACKUPPC_SHARES_CMD nicht gesetzt)")
    return False, names, shares


def under(path, base):
    """True, wenn path gleich base ist oder darunter liegt."""
    return path == base or path.startswith(base.rstrip("/") + "/")


def check_backup(inventory, facts, icinga_hosts):
    available, bpc_names, bpc_shares = load_backuppc()

    inv_by_key = {(i["host"], i["id"]): i for i in inventory if i.get("host") and i.get("id")}
    matched = set()
    redundant = []

    def bpc_hit(names):
        for n in names:
            if n and norm(n) in bpc_names:
                matched.add(norm(n))
                return norm(n)
        return None

    for px in [i for i in inventory if i["bs"] == "P"]:
        rc, out, err = ssh_cmd(px, PX_PROBE, timeout=180)
        if rc != 0:
            warnings.append(f"Backup-Abdeckung: {px['name']} nicht abfragbar ({err.strip()[:100]})")
            continue
        body, _, jobs_txt = out.partition("\nJOBS\n")
        jobs = parse_jobs(jobs_txt)
        node = ""
        for ln in body.splitlines():
            f = ln.split("|")
            if f[0] == "NODE":
                node = f[1]
            if f[0] != "GUEST" or len(f) < 6:
                continue
            vmid, typ, gname, status, b0raw = f[1], f[2], f[3], f[4], f[5]
            if status != "running":
                continue
            inv = inv_by_key.get((px["name"], vmid), {})
            names = {gname, inv.get("name", ""), inv.get("ip", "")}
            if inv.get("name") in facts:
                names.add(facts[inv["name"]]["hostname"])
            label = f"{inv.get('name') or gname} ({px['name']}/{vmid})"
            # Datenplatten: lxc "mp0=/pfad", qemu "scsi1" (Pfad im Gast unbekannt)
            b0 = {}
            for item in [x for x in b0raw.split(",") if x]:
                disk, _, path = item.partition("=")
                b0[disk] = (path.rstrip("/") or "/") if path else ""
            job = covered_by_job(jobs, vmid, node)
            key = bpc_hit(names) if available else None
            shares = bpc_shares.get(key) if key else None

            if not job:
                if excepted(names, "pbs"):
                    infos.append(f"PBS: {label} in keinem Job - bekannte Ausnahme")
                else:
                    warnings.append(f"PBS: {label} ist in keinem aktiven Backup-Job")

            if b0 and available:
                if not key:
                    if excepted(names, "backuppc"):
                        infos.append(f"BackupPC: {label} Datenplatten {', '.join(b0)} ohne Backup - bekannte Ausnahme")
                    else:
                        errors.append(f"Backup-Luecke: {label} Datenplatten {', '.join(b0)} sind aus PBS ausgenommen "
                                      "(backup=0), der Host steht aber nicht in BackupPC")
                elif shares is not None:
                    for disk, path in b0.items():
                        if path:
                            ok = any(s != "/" and (under(path, s) or under(s, path)) for s in shares)
                        else:
                            ok = any(s != "/" for s in shares)
                        if not ok and not excepted(names, "backuppc"):
                            where = f"{disk} ({path})" if path else disk
                            warnings.append(f"Backup-Luecke? {label}: Datenplatte {where} ist aus PBS ausgenommen, "
                                            f"BackupPC hat dafuer keine eigene Freigabe ({', '.join(shares)})")

            if job and key and shares:
                data_paths = [p for p in b0.values() if p]
                if typ == "qemu" and b0 and not data_paths:
                    double = [s for s in shares if s == "/"]
                else:
                    double = [s for s in shares if not any(under(s, p) for p in data_paths)]
                if double:
                    if excepted(names, "redundanz"):
                        infos.append(f"Redundanz {label}: {', '.join(double)} - bekannte Ausnahme")
                    else:
                        redundant.append(f"{inv.get('name') or gname} ({bpc_names[key]}: {', '.join(double)})")

    if redundant:
        warnings.append(f"Daten doppelt gesichert ({len(redundant)} Gaeste): BackupPC sichert Pfade, die bereits im "
                        f"PBS-Image enthalten sind (keine Datenplatte mit backup=0) - Grundsatz: System als Image, "
                        f"Daten genau einmal. Betroffen: {'; '.join(sorted(redundant))}")

    if available:
        for h in inventory:
            if h["typ"] not in ("P", "N") or "1" not in (h.get("ky"), h.get("up")):
                continue
            names = {h["name"], h["ip"]}
            if h["name"] in facts:
                names.add(facts[h["name"]]["hostname"])
            if not bpc_hit(names):
                if excepted(names, "backuppc"):
                    infos.append(f"BackupPC: {h['name']} nicht enthalten - bekannte Ausnahme")
                else:
                    warnings.append(f"BackupPC: physisches System {h['name']} steht nicht in BackupPC")

    if icinga_hosts is not None and bpc_names:
        watched = {norm(((r.get("attrs") or {}).get("vars") or {}).get("backuppc_hostname") or "")
                   for r in icinga_hosts}
        for n, h in sorted(bpc_names.items()):
            if n not in watched:
                warnings.append(f"BackupPC-Host {h}: im Monitoring ohne backuppc_hostname - Frische wird nicht ueberwacht")

    if bpc_names:
        inv_names = {norm(i["name"]) for i in inventory} | {norm(f["hostname"]) for f in facts.values()}
        orphans = sorted(h for n, h in bpc_names.items() if n not in inv_names and n not in matched)
        if orphans:
            infos.append(f"BackupPC-Hosts ohne Inventar-Eintrag (Altlast oder extern?): {', '.join(orphans)}")


# --------------------------------------------------------------------------
def main():
    global EXCEPTIONS
    run = Path(sys.argv[1]) if len(sys.argv) > 1 else latest_run_dir()
    if run is None or not run.exists():
        print("Kein Wochenlauf gefunden", file=sys.stderr)
        return 2
    started_txt = (run / "started").read_text().strip() if (run / "started").exists() else None
    run_start = datetime.fromisoformat(started_txt).timestamp() if started_txt else time.time() - 6 * 3600

    EXCEPTIONS, exc_err = load_exceptions()
    if exc_err:
        warnings.append(exc_err)
    inventory = load_inventory()

    stopped = {norm(r["name"]) for r in read_report(run / "inventory" / "report.txt") if r["kind"] == "STOPPED"}
    stopped |= {r["ip"] for r in read_report(run / "inventory" / "report.txt") if r["kind"] == "STOPPED" and r["ip"]}

    expect_reboot = {norm(r["host"]) for r in read_status(run / "update" / "last_run.status")
                     if r["result"] in ("REBOOT_QUEUED", "REBOOT_COVERED")}

    targets = [i for i in inventory
               if i["bs"] in ("D", "P", "U", "S")
               and "1" in (i.get("up"), i.get("ky"), i.get("rs"), i.get("sh"))
               and norm(i["name"]) not in stopped and i["ip"] not in stopped]

    facts = check_hosts(targets, run_start, expect_reboot)
    check_logs(targets, facts, run_start)
    icinga_hosts = check_icinga()
    check_backup(inventory, facts, icinga_hosts)

    state = "CRITICAL" if errors else "WARNING" if warnings else "OK"
    state_de = {"OK": "OK", "WARNING": "Hinweise", "CRITICAL": "FEHLER"}[state]
    out = [f"SysMaint Nachkontrolle {run.name}: {state_de} ({len(errors)} Fehler, {len(warnings)} Hinweise)", ""]
    out.append(f"Geprueft: {len(targets)} laufende Systeme, davon {len(facts)} erreichbar. "
               f"Wochenlauf-Start {started_txt or '?'}.")
    for title, items in (("FEHLER", errors), ("Hinweise", warnings), ("Info", infos)):
        if items:
            out.append("")
            out.append(f"{title} ({len(items)}):")
            out.extend(f"  - {i}" for i in items)
    if EXCEPTIONS:
        out.append("")
        out.append(f"Beruecksichtigte Ausnahmen: {len(EXCEPTIONS)} (Quelle: Ausnahmen-Seite in BookStack)")

    (run / "verify.txt").write_text("\n".join(out) + "\n")
    write_status(LOG_DIR / "last_verify.status", state, len(errors), len(warnings),
                 {"run": run.name, "checked": datetime.now().isoformat(timespec="seconds")})
    print("\n".join(out))
    return {"OK": 0, "WARNING": 1, "CRITICAL": 2}[state]


EXCEPTIONS = []

if __name__ == "__main__":
    sys.exit(main())
