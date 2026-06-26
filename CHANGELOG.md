# Changelog

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
