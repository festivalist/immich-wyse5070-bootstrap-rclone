#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/immich"
DATA_MOUNT="/mnt/immich-data"
BACKUP_MOUNT="/mnt/immich-backup"
LOG_DIR="${BACKUP_MOUNT}/logs"
TS="$(date +%F_%H%M%S)"
LOG_FILE="${LOG_DIR}/immich-backup-${TS}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { printf '[%s] FEHLER: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

findmnt "$DATA_MOUNT" >/dev/null || fail "$DATA_MOUNT ist nicht gemountet."
findmnt "$BACKUP_MOUNT" >/dev/null || fail "$BACKUP_MOUNT ist nicht gemountet."

cd "$APP_DIR"
set -a
. "$APP_DIR/.env"
set +a

DUMP_DIR="${BACKUP_MOUNT}/postgres-dumps"
mkdir -p "$DUMP_DIR" "${BACKUP_MOUNT}/current" "${BACKUP_MOUNT}/versions/${TS}"

# Reihenfolge bewusst: zuerst Datenbank, danach Dateien. So referenziert ein
# Restore im schlimmsten Fall hoechstens Dateien, die noch nicht in der DB sind,
# statt DB-Eintraege ohne zugehoerige Datei.
log "Starte PostgreSQL-Dump."
docker compose exec -T database \
  pg_dumpall --clean --if-exists --username="$DB_USERNAME" \
  | gzip -c > "${DUMP_DIR}/immich-pg-${TS}.sql.gz"

gzip -t "${DUMP_DIR}/immich-pg-${TS}.sql.gz"
log "PostgreSQL-Dump erfolgreich erstellt und gzip-geprueft."

log "Sichere Compose-Dateien und Skripte."
rclone copy "$APP_DIR" "${BACKUP_MOUNT}/current/compose-backup" \
  --include "docker-compose.yml" \
  --include ".env" \
  --include "scripts/**" \
  --exclude "**" \
  --log-file "$LOG_FILE" \
  --log-level INFO

# Hinweis: Synchronisiert wird das gesamte UPLOAD_LOCATION. Darin liegt auch der
# Ordner backups/ mit den von Immich selbst erzeugten automatischen DB-Backups,
# die so ebenfalls auf HDD 2 gesichert werden.
# Taeglich schnell ueber Groesse+Aenderungszeit (schont die USB-Platte).
# Sonntags zusaetzlich eine vollstaendige Pruefsummen-Kontrolle, die auch
# stille Bitfehler (Bit-Rot) auf der Backup-Platte erkennt.
DOW="$(date +%u)"

log "Synchronisiere Immich-Dateien mit Versionierung (Groesse+Zeit)."
rclone sync "${DATA_MOUNT}/photos" "${BACKUP_MOUNT}/current/photos" \
  --backup-dir "${BACKUP_MOUNT}/versions/${TS}/photos" \
  --transfers 4 \
  --checkers 8 \
  --create-empty-src-dirs \
  --log-file "$LOG_FILE" \
  --log-level INFO

if [ "$DOW" = "7" ]; then
  log "Sonntag: vollstaendige Pruefsummen-Kontrolle (rclone check --checksum)."
  rclone check "${DATA_MOUNT}/photos" "${BACKUP_MOUNT}/current/photos" \
    --one-way \
    --checksum \
    --log-file "$LOG_FILE" \
    --log-level INFO
else
  log "Schnelle Bestandskontrolle (rclone check --size-only)."
  rclone check "${DATA_MOUNT}/photos" "${BACKUP_MOUNT}/current/photos" \
    --one-way \
    --size-only \
    --log-file "$LOG_FILE" \
    --log-level INFO
fi

log "Rotiere alte Backups."
find "$DUMP_DIR" -type f -name 'immich-pg-*.sql.gz' -mtime +14 -delete
find "${BACKUP_MOUNT}/versions" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
find "$LOG_DIR" -type f -name 'immich-backup-*.log' -mtime +30 -delete

log "Backup abgeschlossen. Logdatei: $LOG_FILE"
