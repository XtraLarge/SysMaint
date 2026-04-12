#!/usr/bin/env bash
# Synchronisiert .Systems.sh mit dem aktuellen Proxmox-Inventar.
# Ruft tools/sync-proxmox.sh auf.
#
# Verwendung:
#   ./run-proxmox.sh           # Aenderungen vornehmen
#   ./run-proxmox.sh --dry-run # Nur anzeigen, keine Aenderungen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/tools/sync-proxmox.sh" "$@"
