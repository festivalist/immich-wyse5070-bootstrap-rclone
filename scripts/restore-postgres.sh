#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/immich"
DUMP_FILE="${1:-}"

if [ -z "$DUMP_FILE" ]; then
  echo "Verwendung: sudo /opt/immich/scripts/restore-postgres.sh /pfad/zum/dump.sql.gz" >&2
  exit 1
fi
[ -f "$DUMP_FILE" ] || { echo "Dump nicht gefunden: $DUMP_FILE" >&2; exit 1; }

cd "$APP_DIR"
set -a
. "$APP_DIR/.env"
set +a

echo "WARNUNG: Die bestehende Immich-Datenbank wird ueberschrieben."
read -r -p "Zum Fortfahren exakt RESTORE eingeben: " answer
[ "$answer" = "RESTORE" ] || exit 1

# Server- und ML-Container stoppen, damit keine Migrationen den Restore stoeren.
docker compose stop immich-server immich-machine-learning

# Datenbank-Container sicher gestartet halten und auf Bereitschaft warten.
docker compose up -d database
for _ in $(seq 1 30); do
  if docker compose exec -T database pg_isready -U "$DB_USERNAME" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# WICHTIG (geaendert gegenueber dem Handbuch):
# pg_dumpall setzt den search_path im Dump auf leer
# (SELECT pg_catalog.set_config('search_path', '', false);).
# Beim Einspielen scheitert dadurch die VectorChord-/pgvector-Erweiterung,
# die Immich zwingend benoetigt. Der folgende sed-Ausdruck korrigiert das
# und entspricht der offiziellen Immich-Restore-Anleitung.
gunzip -c "$DUMP_FILE" \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker compose exec -T database \
      psql --username="$DB_USERNAME" --dbname=postgres

docker compose up -d
docker compose ps
