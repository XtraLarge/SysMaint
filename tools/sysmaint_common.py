"""Gemeinsame Helfer fuer die Python-Werkzeuge von SysMaint.

Alle umgebungsspezifischen Werte (Hosts, URLs, Kommandos) kommen aus
Umgebungsvariablen, die run-weekly.sh / run-verify.sh aus der Runtime-Config
(/etc/sysmaint/config.sh) exportieren. Das Repository bleibt so frei von
internen Namen.
"""

import fnmatch
import os
import re
import subprocess
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
LOG_DIR = BASE_DIR / "logs"
WEEKLY_ROOT = Path(os.environ.get("WEEKLY_LOG_ROOT", LOG_DIR / "weekly"))

PROBLEM_RESULTS = {"FAILED", "AUDIT-FAILED", "UNREACHABLE", "REBOOT_FAILED"}


def norm(name):
    """Vergleichsform eines Hostnamens: klein, ohne Domain, nur a-z0-9."""
    name = (name or "").strip().lower()
    if not re.match(r"^\d+\.\d+\.\d+\.\d+$", name):
        name = name.split(".")[0]
    return re.sub(r"[^a-z0-9]", "", name)


def sh(cmd, timeout=120):
    """Fuehrt ein Shell-Kommando aus. Rueckgabe (rc, stdout, stderr)."""
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"Timeout nach {timeout}s"


def load_inventory():
    rc, out, err = sh(str(BASE_DIR / "tools" / "inventory-list.sh"), timeout=30)
    if rc != 0:
        raise RuntimeError(f"Inventar nicht lesbar: {err.strip()}")
    lines = out.splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, ln.split("\t"))) for ln in lines[1:] if ln.strip()]


def load_exceptions():
    """Liest die Ausnahmen ueber EXCEPTIONS_CMD.

    Erwartet je Zeile: HOST|PRUEFUNG|SEIT|GRUND. HOST darf Platzhalter
    enthalten (k3s-node[2-9], k3s-node*). PRUEFUNG '*' gilt fuer alles.
    Rueckgabe (liste, fehlertext_oder_None).
    """
    cmd = os.environ.get("EXCEPTIONS_CMD", "").strip()
    if not cmd:
        return [], None
    rc, out, err = sh(cmd, timeout=60)
    if rc != 0:
        return [], f"Ausnahmenliste nicht lesbar (rc={rc}): {err.strip()[:200]}"
    result = []
    for ln in out.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = [p.strip() for p in ln.split("|")]
        if len(parts) < 2 or parts[0].lower() in ("host", "system"):
            continue
        parts += [""] * (4 - len(parts))
        result.append({"host": parts[0], "check": parts[1].lower(),
                       "since": parts[2], "reason": parts[3]})
    return result, None


def find_exception(exceptions, names, check):
    """Passende Ausnahme fuer einen der Namen und die Pruefung, sonst None."""
    cands = {n.lower() for n in names if n} | {norm(n) for n in names if n}
    for e in exceptions:
        # "backup" deckt beide Backup-Pruefungen ab (BackupPC und PBS)
        if e["check"] not in (check, "*") and not (e["check"] == "backup" and check in ("backuppc", "pbs")):
            continue
        pat = e["host"].lower()
        if any(fnmatch.fnmatch(c, pat) or c == norm(pat) for c in cands):
            return e
    return None


def read_status(path):
    """Liest eine last_run.status von manage.sh."""
    rows = []
    p = Path(path)
    if not p.exists():
        return rows
    for ln in p.read_text(errors="replace").splitlines():
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("|", 4)
        if len(f) == 5:
            rows.append({"host": f[0], "ip": f[1], "flag": f[2], "result": f[3], "detail": f[4]})
    return rows


def read_report(path):
    """Liest einen Report von sync-proxmox.sh (ART|PX|TYP|VMID|NAME|IP|DETAIL)."""
    rows = []
    p = Path(path)
    if not p.exists():
        return rows
    for ln in p.read_text(errors="replace").splitlines():
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("|", 6)
        f += [""] * (7 - len(f))
        rows.append(dict(zip(["kind", "px", "typ", "vmid", "name", "ip", "detail"], f)))
    return rows


def latest_run_dir():
    if not WEEKLY_ROOT.exists():
        return None
    runs = sorted(d for d in WEEKLY_ROOT.iterdir() if d.is_dir())
    return runs[-1] if runs else None


def write_status(path, state, errors, warnings, extra=None):
    lines = [f"state={state}", f"errors={errors}", f"warnings={warnings}"]
    for k, v in (extra or {}).items():
        lines.append(f"{k}={v}")
    tmp = Path(str(path) + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(path)
