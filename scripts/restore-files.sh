#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="${1:-/mnt/immich-backup/current/photos}"
TARGET="/mnt/immich-data/photos"

[ -d "$SOURCE" ] || { echo "Quelle nicht gefunden: $SOURCE" >&2; exit 1; }
findmnt /mnt/immich-data >/dev/null || { echo "/mnt/immich-data ist nicht gemountet" >&2; exit 1; }
findmnt /mnt/immich-backup >/dev/null || { echo "/mnt/immich-backup ist nicht gemountet" >&2; exit 1; }

echo "Quelle: $SOURCE"
echo "Ziel:   $TARGET"
echo "WARNUNG: Dateien werden in das Produktivverzeichnis kopiert."
read -r -p "Zum Fortfahren exakt RESTORE-FILES eingeben: " answer
[ "$answer" = "RESTORE-FILES" ] || exit 1

rclone copy "$SOURCE" "$TARGET" \
  --checksum \
  --transfers 4 \
  --checkers 8 \
  --log-level INFO
