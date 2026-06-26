# Immich auf Dell Wyse 5070 — Bootstrap & lokales rclone-Backup (v5)

Hochladefertige Dateien fuer den im Handbuch beschriebenen Aufbau: Immich auf
Ubuntu Server 24.04 LTS, Docker Compose, Intel QuickSync und ein automatisches,
versioniertes lokales Backup auf eine zweite HDD per rclone und systemd-Timer.
Optional: Fernzugriff (Tailscale/DuckDNS/Cloudflare) und ein Offsite-Backup.

> **Was ist neu in v5?** Siehe `CHANGELOG.md`. Kurz: korrekte Tailscale-URL aus
> v4 uebernommen, Immich auf den Major `v2` gepinnt, Valkey 9, DB-Healthcheck mit
> `depends_on: service_healthy`, schonenderer Backup-Lauf (taeglich Groesse+Zeit,
> sonntags volle Pruefsumme), `RequiresMountsFor` im Backup-Timer und ein
> optionales Offsite-Backup-Skript fuer die 3-2-1-Regel.

## Repo-Struktur

```
immich-wyse5070-bootstrap-rclone/
├── README.md
├── CHANGELOG.md
├── bootstrap.sh                 # Einstiegspunkt, richtet das gesamte System ein
├── config/
│   ├── docker-compose.yml        # Referenz (bootstrap.sh schreibt eine eigene Kopie)
│   ├── immich.env.template       # Vorlage fuer .env (bootstrap.sh erzeugt .env automatisch)
│   ├── offsite.env.template      # Vorlage fuer das optionale Offsite-Backup
│   └── remote-access/            # Beispiel-Compose: NPM, DuckDNS, Cloudflare-DDNS, Tunnel
├── scripts/
│   ├── immich-backup.sh
│   ├── immich-offsite.sh         # optionales Offsite-Backup (standardmaessig AUS)
│   ├── restore-postgres.sh
│   ├── restore-files.sh
│   ├── healthcheck.sh
│   └── setup-remote-access.sh    # interaktiver Fernzugriff (Tailscale / DuckDNS / Cloudflare)
└── systemd/
    ├── immich-backup.service
    ├── immich-backup.timer
    ├── immich-offsite.service    # installiert, aber NICHT aktiviert
    └── immich-offsite.timer      # installiert, aber NICHT aktiviert
```

`bootstrap.sh` ist in sich vollstaendig: Es schreibt `docker-compose.yml`, `.env`,
alle Skripte und die systemd-Units selbst nach `/opt/immich` bzw.
`/etc/systemd/system`. Die Dateien unter `config/`, `scripts/` und `systemd/` sind
inhaltsgleiche Referenzkopien fuer Versionskontrolle und manuellen Aufbau.

## Schnellstart

Auf einem frisch installierten Ubuntu Server 24.04 LTS:

```bash
# 1. Skript herunterladen (Repo-URL anpassen, siehe Checkliste)
curl -fsSL https://raw.githubusercontent.com/festivalist/immich-wyse5070-bootstrap-rclone/main/bootstrap.sh -o bootstrap.sh

# 2. Sichtpruefung
less bootstrap.sh

# 3. Ausfuehren
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Das Skript fragt interaktiv die beiden Datentraeger ab und verlangt eine exakte
`FORMAT /dev/sdX`-Bestaetigung, bevor formatiert wird.

## Anpass-Checkliste (vor dem Lauf pruefen)

| # | Stelle | Datei / Ort | Was anpassen | Pflicht |
|---|--------|-------------|--------------|---------|
| 1 | Repo-URL | Download-Befehl oben / Handbuch | `<DEIN-USER>` durch deinen GitHub-Namespace ersetzen | Ja |
| 2 | Zeitzone | `bootstrap.sh` → `TIMEZONE` | Standard `Europe/Berlin`, ggf. ändern | Nur bei Abweichung |
| 3 | SSH auf LAN beschränken | `bootstrap.sh` → `SSH_LAN_CIDR` | z. B. `192.168.178.0/24` eintragen, sonst SSH für alle offen | Empfohlen |
| 4 | Immich-Port | `bootstrap.sh` → `IMMICH_PORT` | Standard `2283`, nur bei Konflikt ändern | Nein |
| 5 | Daten-HDD | interaktive Abfrage beim Lauf | richtiges Gerät wählen (z. B. `/dev/sda`) | Ja |
| 6 | Backup-HDD | interaktive Abfrage beim Lauf | richtiges Gerät wählen (z. B. `/dev/sdb`) | Ja |
| 7 | DB-Passwort | `/opt/immich/.env` | wird automatisch zufällig erzeugt — nichts tun | Auto |
| 8 | Immich-Version | `/opt/immich/.env` → `IMMICH_VERSION` | Standard `v2` (Major gepinnt). Major-Upgrade bewusst durchführen | Auto |
| 9 | Optional HTTPS | Nginx Proxy Manager | Domain/DynDNS, Router-Portfreigabe, Proxy-Host | Optional |
| 10 | Optional Offsite | `/opt/immich/offsite.env` | rclone-Remote anlegen, dann Timer aktivieren | Empfohlen |

## Was nach dem Lauf zu tun ist

1. Weboberfläche öffnen: `http://<server-ip>:2283`
2. Ersten Administrator anlegen, danach pro Person einen eigenen Benutzer.
3. Backup einmal manuell testen:
   `sudo systemctl start immich-backup.service` und Log prüfen.
4. Healthcheck ausführen: `sudo /opt/immich/scripts/healthcheck.sh`

## Backup-Verhalten

- **Täglich 03:15 Uhr** (systemd-Timer `immich-backup.timer`):
  PostgreSQL-Dump (`pg_dumpall`, gzip-geprüft), Sicherung von `docker-compose.yml`,
  `.env` und Skripten sowie versionierte Synchronisation der Fotos auf HDD 2.
- Die nächtliche Synchronisation vergleicht **Größe + Änderungszeit** (schnell,
  schont die USB-Platte). **Sonntags** läuft zusätzlich eine **vollständige
  Prüfsummen-Kontrolle** (`rclone check --checksum`), die auch stille Bitfehler
  (Bit-Rot) erkennt.
- Der Backup-Timer startet nur, wenn **beide HDDs gemountet** sind
  (`RequiresMountsFor`). Gelöschte/geänderte Dateien landen versioniert unter
  `versions/<Zeitstempel>/` und werden nach 30 Tagen aufgeräumt.

## Fernzugriff (Backup/Ansehen von unterwegs)

`bootstrap.sh` bietet am Ende an, den Fernzugriff einzurichten; alternativ jederzeit:

```bash
sudo /opt/immich/scripts/setup-remote-access.sh
```

| Option | Portfreigabe | Upload großer Videos | Für wen |
|--------|--------------|----------------------|---------|
| Tailscale | nein | ohne Limit | empfohlen für reine Eigen-/Familiennutzung |
| DuckDNS + Nginx Proxy Manager | 80/443 | ohne Limit | öffentlicher Zugriff, kostenlose Subdomain |
| Cloudflare DNS + DDNS + NPM | 80/443 | ohne Limit (DNS-only) | eigene Domain bei Cloudflare |
| Cloudflare Tunnel | nein | **max. 100 MB** | nur zum Ansehen, nicht zum Backup großer Dateien |

Hintergrund Vodafone Station: Deren DynDNS-Client unterstützt nur wenige Anbieter.
Die Optionen 2 und 3 lösen das, indem ein **DDNS-Updater-Container auf dem Wyse**
den DNS-Eintrag aktualisiert — unabhängig vom Router.

## Offsite-Backup (3-2-1-Regel) — empfohlen, optional

Beide HDDs stehen am selben Ort und hängen am selben USB-Bus. Gegen Überspannung,
Diebstahl oder einen defekten USB-SATA-Controller hilft nur ein **Offsite-Ziel**.
`bootstrap.sh` installiert dafür `immich-offsite.sh` samt systemd-Units, lässt sie
aber **deaktiviert**. Aktivierung:

```bash
# 1. rclone-Remote anlegen (z. B. Cloud-Speicher), Name z. B. "offsite"
sudo rclone config

# 2. Konfiguration anlegen und OFFSITE_REMOTE setzen
sudo cp /opt/immich/offsite.env.template /opt/immich/offsite.env
sudo nano /opt/immich/offsite.env

# 3. Täglichen Offsite-Timer aktivieren (läuft 04:30 Uhr, nach dem lokalen Backup)
sudo systemctl enable --now immich-offsite.timer
```

Das Skript lädt nur die **bereits lokal gesicherten** Daten von HDD 2 ins
Offsite-Ziel und rührt die Produktivdaten nicht an.

## Wichtige Hinweise

- **Immich-Version gepinnt:** `IMMICH_VERSION=v2` zieht automatisch alle
  `v2.x`-Updates, aber keinen unbemerkten Sprung auf einen nächsten Major.
  Ein Major-Upgrade bewusst durchführen und vorher das Immich-Changelog lesen.
- **Restore:** `restore-postgres.sh` enthält die für die VectorChord-/pgvector-
  Erweiterung nötige `search_path`-Korrektur. Ohne sie schlägt ein
  Datenbank-Restore fehl. Alternativ kann ab Immich v2.5.0 auch die in der
  Weboberfläche integrierte Wiederherstellung genutzt werden.
- **Machine Learning:** Das Standard-ML-Image nutzt die CPU. Für Intel-GPU-
  Beschleunigung wäre das `-openvino`-Image plus `hwaccel.ml.yml` nötig. Auf dem
  Wyse 5070 ist CPU-ML in der Regel ausreichend, der Erstimport (Gesichter,
  Smart-Search) dauert aber spürbar.
