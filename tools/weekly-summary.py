#!/usr/bin/env python3
"""Fasst einen Wochenlauf (logs/weekly/<lauf>) zusammen.

Schreibt <lauf>/summary.txt (erste Zeile = Mail-Betreff) und
logs/last_weekly.status fuer das Monitoring.

Einordnung:
  Fehler   = Task-Fehler auf laufenden Hosts ohne Ausnahme, Schritt ohne Ergebnis
  Hinweise = Inventar-/Monitoring-Abweichungen, die eine Pruefung brauchen
  Info     = gestoppte Gaeste, bekannte Ausnahmen, automatische Inventar-Aenderungen, Reboots

Exit-Code: 0 = OK, 1 = Hinweise, 2 = Fehler
"""

import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sysmaint_common import (LOG_DIR, PROBLEM_RESULTS, find_exception, load_exceptions,  # noqa: E402
                             load_inventory, norm, read_report, read_status, write_status)

TASK_STEPS = ["keys", "shell", "rsyslog", "autofs", "unattended", "update"]
STEP_TITLES = {
    "inventory": "Inventar-Abgleich", "monitoring": "Monitoring-Abgleich", "keys": "SSH-Keys",
    "shell": "Shell-Baseline", "rsyslog": "RSyslog", "autofs": "AutoFS",
    "unattended": "unattended-upgrades (Audit)", "update": "Updates",
}


def main():
    if len(sys.argv) != 2:
        print("Aufruf: weekly-summary.py <lauf-verzeichnis>", file=sys.stderr)
        return 2
    run = Path(sys.argv[1])
    errors, warnings, infos, reboots = [], [], [], []

    steps = {}
    steps_file = run / "steps.tsv"
    if steps_file.exists():
        for ln in steps_file.read_text().splitlines()[1:]:
            f = ln.split("\t")
            if len(f) == 3:
                steps[f[0]] = {"rc": f[1], "sec": f[2]}

    try:
        inventory = load_inventory()
    except RuntimeError as exc:
        inventory = []
        errors.append(str(exc))
    by_ip = {i["ip"]: i for i in inventory}

    exceptions, exc_err = load_exceptions()
    if exc_err:
        warnings.append(exc_err)

    inv_report = read_report(run / "inventory" / "report.txt")
    stopped = {norm(r["name"]) for r in inv_report if r["kind"] == "STOPPED"}
    stopped |= {r["ip"] for r in inv_report if r["kind"] == "STOPPED" and r["ip"]}

    def names_for(host, ip):
        names = {host, ip}
        if ip in by_ip:
            names.add(by_ip[ip]["name"])
        return names

    # --- Task-Schritte ---------------------------------------------------
    counts = {}
    for step in TASK_STEPS:
        meta = steps.get(step)
        if meta is None:
            errors.append(f"{STEP_TITLES[step]}: Schritt wurde nicht ausgefuehrt")
            continue
        if meta["rc"] == "skip":
            infos.append(f"{STEP_TITLES[step]}: uebersprungen (--skip)")
            continue
        rows = read_status(run / step / "last_run.status")
        if not rows and meta["rc"] != "0":
            errors.append(f"{STEP_TITLES[step]}: endete mit rc={meta['rc']} ohne Statusdatei")
            continue
        c = Counter()
        for r in rows:
            res = r["result"]
            if res in PROBLEM_RESULTS:
                names = names_for(r["host"], r["ip"])
                if any(norm(n) in stopped or n in stopped for n in names):
                    c["gestoppt"] += 1
                    continue
                exc = find_exception(exceptions, names, step)
                if exc:
                    c["Ausnahme"] += 1
                    infos.append(f"{STEP_TITLES[step]}: {r['host']} {res} - bekannte Ausnahme ({exc['reason']})")
                    continue
                c["Fehler"] += 1
                errors.append(f"{STEP_TITLES[step]}: {r['host']} ({r['ip']}) {res} - {r['detail']}")
            elif res == "REBOOT_QUEUED":
                reboots.append(f"{r['host']} ({r['ip']}): {r['detail']}")
            elif res == "REBOOT_COVERED":
                c["Reboot ueber Host"] += 1
            elif res in ("OK", "SKIPPED"):
                c[res] += 1
        counts[step] = c

    # --- Inventar-Abgleich -----------------------------------------------
    inv_rc = steps.get("inventory", {}).get("rc")
    if inv_rc not in (None, "0", "1", "skip"):
        errors.append(f"Inventar-Abgleich: rc={inv_rc} (Proxmox-Host nicht abfragbar?)")
    for r in inv_report:
        kind = r["kind"]
        label = f"{r['name']} ({r['px']}/{r['vmid']})"
        if kind == "STOPPED":
            continue
        if kind in ("NEW", "MOVED"):
            infos.append(f"Inventar automatisch ergaenzt: {kind} {label} - {r['detail']}")
            continue
        if find_exception(exceptions, {r["name"], r["ip"]}, "inventory"):
            infos.append(f"Inventar: {kind} {label} - bekannte Ausnahme")
            continue
        if kind == "PXERROR":
            errors.append(f"Inventar: {r['px']} nicht abfragbar")
        else:
            warnings.append(f"Inventar: {kind} {label} - {r['detail']}")

    # --- Monitoring-Abgleich ---------------------------------------------
    mon_file = run / "monitoring" / "report.txt"
    if mon_file.exists():
        for ln in mon_file.read_text().splitlines():
            f = ln.split("|", 3)
            if len(f) != 4:
                continue
            kind, name, addr, detail = f
            if kind == "ERROR":
                warnings.append(f"Monitoring: {detail}")
            elif kind == "ORPHAN":
                infos.append(f"Monitoring: {name} ({addr}) {detail}")
            elif kind == "MISSING" and (norm(name) in stopped or addr in stopped):
                continue
            elif find_exception(exceptions, {name, addr}, "monitoring"):
                infos.append(f"Monitoring: {name} ({addr}) - bekannte Ausnahme")
            else:
                warnings.append(f"Monitoring: {name} ({addr}) {detail}")

    # --- Ausgabe ---------------------------------------------------------
    state = "CRITICAL" if errors else "WARNING" if warnings else "OK"
    started = (run / "started").read_text().strip() if (run / "started").exists() else "?"
    finished = (run / "finished").read_text().strip() if (run / "finished").exists() else "?"
    state_de = {"OK": "OK", "WARNING": "Hinweise", "CRITICAL": "FEHLER"}[state]

    out = [f"SysMaint Wochenlauf {run.name}: {state_de} ({len(errors)} Fehler, {len(warnings)} Hinweise)", ""]
    out.append(f"Start {started} - Ende {finished}")
    out.append(f"Logs: {run}")
    out.append("")
    out.append("Schritte:")
    for name in ["inventory", "monitoring"] + TASK_STEPS:
        meta = steps.get(name)
        if not meta:
            continue
        c = counts.get(name)
        cs = ", ".join(f"{v} {k}" for k, v in sorted(c.items())) if c else ""
        out.append(f"  {STEP_TITLES[name]:<30} rc={meta['rc']:<4} {int(meta['sec'] or 0) // 60:>3} min  {cs}")
    for title, items in (("FEHLER", errors), ("Hinweise", warnings),
                         ("Geplante Reboots", reboots), ("Info", infos)):
        if items:
            out.append("")
            out.append(f"{title} ({len(items)}):")
            out.extend(f"  - {i}" for i in items)
    gestoppt = sorted({r["name"] for r in inv_report if r["kind"] == "STOPPED"})
    if gestoppt:
        out.append("")
        out.append(f"Gestoppte Gaeste (uebersprungen): {', '.join(gestoppt)}")
    out.append("")
    out.append("Die Nachkontrolle (Logs, Erreichbarkeit, Backup-Abdeckung) folgt separat.")

    (run / "summary.txt").write_text("\n".join(out) + "\n")
    write_status(LOG_DIR / "last_weekly.status", state, len(errors), len(warnings),
                 {"run": run.name, "finished": finished})
    print("\n".join(out))
    return {"OK": 0, "WARNING": 1, "CRITICAL": 2}[state]


if __name__ == "__main__":
    sys.exit(main())
