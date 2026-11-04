#!/usr/bin/env python3
"""Verschickt eine Textdatei als Mail ueber den lokalen MTA (sendmail).

Erste Zeile der Datei = Betreff, Rest = Text. Es werden keine Zugangsdaten
benoetigt; der lokale MTA des Management-Hosts muss zustellen koennen.

Konfiguration ueber Umgebung (aus /etc/sysmaint/config.sh exportiert):
  REPORT_MAIL_TO    Empfaenger (Pflicht)
  REPORT_MAIL_FROM  Absender (Standard: root@<hostname>)
  REPORT_SENDMAIL   Pfad zu sendmail (Standard: /usr/sbin/sendmail)
"""

import os
import socket
import subprocess
import sys
from email.mime.text import MIMEText
from email.utils import formatdate, make_msgid


def main():
    if len(sys.argv) != 2:
        print("Aufruf: send-report.py <datei>", file=sys.stderr)
        return 2
    to = os.environ.get("REPORT_MAIL_TO", "").strip()
    if not to:
        print("REPORT_MAIL_TO nicht gesetzt - keine Mail", file=sys.stderr)
        return 1
    sender = os.environ.get("REPORT_MAIL_FROM") or f"root@{socket.getfqdn()}"
    sendmail = os.environ.get("REPORT_SENDMAIL", "/usr/sbin/sendmail")

    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    subject, _, body = text.partition("\n")
    msg = MIMEText(body.lstrip("\n"), "plain", "utf-8")
    msg["Subject"] = subject.strip()
    msg["From"] = sender
    msg["To"] = to
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=sender.split("@")[-1])

    proc = subprocess.run([sendmail, "-oi", "-f", sender, to], input=msg.as_bytes(),
                          capture_output=True, timeout=60)
    if proc.returncode != 0:
        print(f"sendmail rc={proc.returncode}: {proc.stderr.decode(errors='replace')}", file=sys.stderr)
        return 1
    print(f"Bericht an {to} uebergeben: {subject.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
