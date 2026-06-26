#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/immich"
BACKUP_MOUNT="/mnt/immich-backup"

echo "== System =="
hostnamectl --static
uptime

echo
echo "== Mounts =="
findmnt /mnt/immich-data || true
findmnt /mnt/immich-backup || true

echo
echo "== Speicherplatz =="
df -h / /mnt/immich-data /mnt/immich-backup

echo
echo "== Docker Compose =="
cd "$APP_DIR"
docker compose ps

echo
echo "== Letzte Backup-Dumps =="
ls -lh "$BACKUP_MOUNT/postgres-dumps" 2>/dev/null | tail -n 10 || true

echo
echo "== Backup Timer =="
systemctl --no-pager status immich-backup.timer || true
