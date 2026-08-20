#!/usr/bin/env bash
# Example runtime defaults for SysMaint.
# Productive environments should usually override this file under /etc/sysmaint/config.sh.

DEFAULT_JOBS=${DEFAULT_JOBS:-8}
DEFAULT_REBOOT_DELAY=${DEFAULT_REBOOT_DELAY:-1}
LOCAL_REBOOT_DELAY=${LOCAL_REBOOT_DELAY:-5}

KEYS_MANAGED_DIR=${KEYS_MANAGED_DIR:-/etc/sysmaint/keys/managed}
BACKUP_KEY_FILE=${BACKUP_KEY_FILE:-/etc/sysmaint/keys/backup.pub}

SHELL_PACKAGES_D=${SHELL_PACKAGES_D:-"bash-completion vim less"}
SHELL_PACKAGES_U=${SHELL_PACKAGES_U:-"$SHELL_PACKAGES_D"}
SHELL_PACKAGES_S=${SHELL_PACKAGES_S:-"vim less"}
SHELL_PACKAGES_B=${SHELL_PACKAGES_B:-""}
SHELL_PACKAGES_X=${SHELL_PACKAGES_X:-""}

AUTOFS_PACKAGES_D=${AUTOFS_PACKAGES_D:-"autofs cifs-utils nfs-common sshfs"}
AUTOFS_PACKAGES_U=${AUTOFS_PACKAGES_U:-"$AUTOFS_PACKAGES_D"}
AUTOFS_PACKAGES_S=${AUTOFS_PACKAGES_S:-"autofs cifs-utils nfs-client sshfs"}
AUTOFS_PACKAGES_B=${AUTOFS_PACKAGES_B:-""}
AUTOFS_PACKAGES_X=${AUTOFS_PACKAGES_X:-""}

RSYSLOG_TARGET_HOST=${RSYSLOG_TARGET_HOST:-syslog.home.arpa}
RSYSLOG_TARGET_PORT=${RSYSLOG_TARGET_PORT:-1514}
RSYSLOG_TARGET_PROTOCOL=${RSYSLOG_TARGET_PROTOCOL:-udp}

# ---------------------------------------------------------------------------
# unattended-upgrades: bekannte/akzeptierte surplus-Origins (known-surp)
#
# Space-separated Liste von Host-Namen oder IPs, fuer die ein reines
# Origins-Surplus (osurp>0, omiss=0) NICHT als GAP gemeldet wird, sondern
# als KNOWN-ACCEPTED markiert wird (origins=known-surp<N>).
# Typischer Anwendungsfall: Policy-Rueckbau B->A hinterlaesst ein Surplus-
# Origin auf Hosts, auf denen Apply gesperrt ist (z.B. Kunden-Hosts).
# Eintragen: Name exakt wie in .Systems.sh !Name-Spalte, ODER IP-Adresse.
# Leer = kein Host ist ausgenommen (Default: alles wird als GAP gemeldet).
# ---------------------------------------------------------------------------
UU_KNOWN_SURP_HOSTS=${UU_KNOWN_SURP_HOSTS:-""}
