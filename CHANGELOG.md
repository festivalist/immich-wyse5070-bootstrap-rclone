# Changelog

## v6
Aufbauend auf v5. Migration auf Immich v3 (Stand November 2026).

### Geaendert
- **Immich-Version gepinnt:** `IMMICH_VERSION` von `v2` auf `v3`. Frische
  Installationen ziehen damit die aktuelle v3-Stabilversion (Stand 11/2026:
  v3.3.6). (`.env`-Erzeugung in `bootstrap.sh` und `config/immich.env.template`.)
- **Compose-Template an offizielles v3-Layout angeglichen** (in `bootstrap.sh`
  und `config/docker-compose.yml`):
  - `DB_STORAGE_TYPE: 'HDD'` im Datenbank-Dienst — das Tuning des offiziellen
    Immich-Images fuer Datenbanken auf HDDs (hier: `/mnt/immich-data/postgres`).
  - `MACHINE_LEARNING_MODEL_REVISION: 'v2'` im ML-Dienst — die im offiziellen
    v3-Compose-Template gesetzte Modellgeneration.

### Behoben
- **Zeilenenden normalisiert (CRLF → LF):** Der gesamte Text-Bestand des Repos
  war bis v5 mit Windows-Zeilenenden (CRLF) committet. Ein Download über den
  dokumentierten `curl`-Weg schlug auf Linux sofort fehl
  (`set: pipefail: invalid option name`, weil bash `pipefail\r` als Option
  liest; empirisch verifiziert auf Ubuntu 24.04 / bash 5.2). Alle Textdateien
  sind jetzt LF — der dokumentierte Installationsweg funktioniert.

### Getestet
- In-Place-Migration der Produktiv-Installation v2.7.5 → v3.3.6 am 09.11.2026
  mit exakt dieser Konfiguration: alle Kysely-DB-Migrationen erfolgreich,
  alle vier Container healthy, API antwortet, Heartbeat-Selbsttest bestanden.
  Die Postgres-14-Plattform (Image `14-vectorchord0.4.3-pgvectors0.2.0`) ist
  in v3 weiterhin das offizielle Standard-Image — kein DB-Umzug noetig.

## v5
Aufbauend auf v4. Aktualitaet (Stand Juni 2026) und Robustheit.

### Geaendert
- **Immich-Version gepinnt:** `IMMICH_VERSION` von `release` auf `v2`. Verhindert
  einen unbemerkten Sprung auf den naechsten Major beim `docker compose pull`.
  (`.env`-Erzeugung in `bootstrap.sh` und `config/immich.env.template`.)
- **Valkey 9:** Redis/Valkey-Image von `valkey:8-bookworm` auf `valkey:9`
  angehoben (entspricht dem aktuellen offiziellen Immich-Compose). Healthcheck
  um `interval/timeout/retries/start_period` ergaenzt.
- **DB-Healthcheck:** Der `database`-Dienst hat jetzt einen `pg_isready`-
  Healthcheck. `immich-server` wartet via `depends_on: condition: service_healthy`
  auf Datenbank und Redis — saubererer Start.
- **Schonenderer Backup-Lauf:** Die naechtliche `rclone sync` vergleicht
  Groesse+Aenderungszeit statt jede Datei per Pruefsumme zu lesen. Sonntags
  laeuft zusaetzlich eine vollstaendige `rclone check --checksum`-Kontrolle
  (erkennt Bit-Rot). Schneller und schont die USB-Platte.

### Hinzugefuegt
- **`RequiresMountsFor`** im `immich-backup.service`: Der Timer startet nur,
  wenn beide HDDs (`/mnt/immich-data`, `/mnt/immich-backup`) gemountet sind.
- **Optionales Offsite-Backup** (3-2-1-Regel): `scripts/immich-offsite.sh`,
  `config/offsite.env.template` sowie `systemd/immich-offsite.{service,timer}`.
  Werden vom Bootstrap installiert, aber NICHT aktiviert. Aktivierung per
  `rclone config` + `offsite.env` + `systemctl enable --now immich-offsite.timer`.

## v4
- **Fix:** Korrekte Tailscale-Paketquelle. Primaer der offizielle Installer
  (`https://tailscale.com/install.sh`), als Fallback die korrekte Listendatei
  `<codename>.tailscale-keyring.list`.
- Restore-Postgres wartet auf `pg_isready` und enthaelt die `search_path`-
  Korrektur fuer VectorChord/pgvector.
- `/dev/dri` aus dem ML-Dienst entfernt (ohne `-openvino`-Image wirkungslos).

## v3 (fehlerhaft — nicht verwenden)
- Tailscale-Listen-URL fehlerhaft (`<codename>.tailscale-list` statt
  `<codename>.tailscale-keyring.list`). `curl -f` liefert 404, das Skript bricht
  wegen `set -Eeuo pipefail` ab.
