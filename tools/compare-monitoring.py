#!/usr/bin/env python3
"""Vergleicht das Inventar mit den Hosts im Monitoring (Icinga).

Ausgabe je Befund: ART|NAME|ADRESSE|DETAIL
  MISSING  aktiver Inventar-Host (UP=1 oder KY=1) fehlt im Monitoring
  EXTRA    Monitoring-Host ohne Inventar-Eintrag, der DOWN ist (vermutlich Altlast)
  ORPHAN   Monitoring-Host ohne Inventar-Eintrag, der UP ist (zur Info)
  ERROR    Monitoring nicht abfragbar

Quelle: ICINGA_QUERY_CMD hosts (JSON der Icinga-API).
Exit-Code: 0 = keine Befunde, 1 = Befunde, 2 = Fehler
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sysmaint_common import load_inventory, norm, sh  # noqa: E402


def main():
    cmd = os.environ.get("ICINGA_QUERY_CMD", "").strip()
    if not cmd:
        print("ICINGA_QUERY_CMD nicht gesetzt - Abgleich entfaellt", file=sys.stderr)
        return 0
    rc, out, err = sh(f"{cmd} hosts", timeout=90)
    try:
        hosts = json.loads(out)["results"] if rc == 0 else None
    except (ValueError, KeyError):
        hosts = None
    if hosts is None:
        print(f"ERROR|-|-|Monitoring-Hostliste nicht abrufbar ({err.strip()[:120] or rc})")
        return 2

    inventory = load_inventory()
    inv_ips = {i["ip"] for i in inventory}
    inv_names = {norm(i["name"]) for i in inventory}
    mon_ips, mon_names = set(), set()
    findings = []

    for h in hosts:
        a = h.get("attrs", {})
        name, addr = a.get("name", ""), a.get("address", "")
        mon_names.add(norm(name))
        if addr:
            mon_ips.add(addr)
        if addr and addr not in inv_ips and norm(name) not in inv_names:
            if int(a.get("state", 0)) != 0:
                findings.append(f"EXTRA|{name}|{addr}|im Monitoring, nicht im Inventar und DOWN - Altlast?")
            else:
                findings.append(f"ORPHAN|{name}|{addr}|im Monitoring, nicht im Inventar")

    for i in inventory:
        if "1" not in (i.get("up"), i.get("ky")):
            continue
        if i["ip"] not in mon_ips and norm(i["name"]) not in mon_names:
            findings.append(f"MISSING|{i['name']}|{i['ip']}|aktiv im Inventar, fehlt im Monitoring")

    for f in sorted(findings):
        print(f)
    return 1 if any(not f.startswith("ORPHAN") for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
