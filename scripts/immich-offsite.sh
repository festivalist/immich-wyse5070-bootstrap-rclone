#!/usr/bin/env bash
set -Eeuo pipefail

# Optionales Offsite-Backup (3-2-1-Regel) ueber rclone in ein beliebiges
# Cloud-/Remote-Ziel. Standardmaessig NICHT aktiv.
#
# Aktivierung:
#   1. Remote anlegen:   sudo rclone config        (Name z. B. "offsite")
#   2. Konfig anlegen:   sudo cp /opt/immich/offsite.env.template /opt/immich/offsite.env
#                        sudo nano /opt/immich/offsite.env        (OFFSITE_REMOTE setzen)
#   3. Timer aktivieren: sudo systemctl enable --now immich-offsite.timer
#
# Das Skript laedt NUR die bereits lokal gesicherten Daten (HDD 2) ins
# Offsite-Ziel und beruehrt die Produktivdaten nicht.

APP_DIR="/opt/immich"
BACKUP_MOUNT="/mnt/immich-backup"
ENV_FILE="${APP_DIR}/offsite.env"
LOG_DIR="${BACKUP_MOUNT}/logs"
TS="$(date +%F_%H%M%S)"
LOG_FILE="${LOG_DIR}/immich-offsite-${TS}.log"

if [ ! -f "$ENV_FILE" ]; then
  echo "Offsite-Backup ist nicht konfiguriert."
  echo "Lege ${ENV_FILE} an (Beispiel: OFFSITE_REMOTE=offsite:immich-backup)"
  echo "und richte mit 'sudo rclone config' ein passendes Remote ein."
  exit 0
fi

set -a
. "$ENV_FILE"
set +a

[ -n "${OFFSITE_REMOTE:-}" ] || { echo "OFFSITE_REMOTE ist in ${ENV_FILE} nicht gesetzt." >&2; exit 1; }
findmnt "$BACKUP_MOUNT" >/dev/null || { echo "$BACKUP_MOUNT ist nicht gemountet." >&2; exit 1; }

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

log "Starte Offsite-Sync nach ${OFFSITE_REMOTE}."
# Aktueller Stand (Fotos inkl. Immich-eigener backups/, Compose-Backup).
rclone sync "${BACKUP_MOUNT}/current" "${OFFSITE_REMOTE}/current" \
  --transfers 4 --checkers 8 --fast-list \
  --log-file "$LOG_FILE" --log-level INFO
# PostgreSQL-Dumps der letzten 30 Tage zusaetzlich sichern.
rclone copy "${BACKUP_MOUNT}/postgres-dumps" "${OFFSITE_REMOTE}/postgres-dumps" \
  --max-age 30d \
  --log-file "$LOG_FILE" --log-level INFO

log "Offsite-Sync abgeschlossen. Logdatei: $LOG_FILE"
