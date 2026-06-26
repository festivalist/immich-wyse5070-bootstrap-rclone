#!/usr/bin/env bash
set -Eeuo pipefail

# Immich Bootstrap fuer Dell Wyse 5070 / Ubuntu Server 24.04 LTS
# Ziel: Docker, Immich, Intel QuickSync, zwei HDDs und lokales rclone-Backup
# Das Skript ist fuer ein frisch installiertes Ubuntu-System vorgesehen.

APP_DIR="/opt/immich"
DATA_MOUNT="/mnt/immich-data"
BACKUP_MOUNT="/mnt/immich-backup"
TIMEZONE="Europe/Berlin"
IMMICH_PORT="2283"
SSH_LAN_CIDR=""

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  printf '[%s] FEHLER: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    fail "Dieses Skript muss mit sudo oder als root ausgefuehrt werden."
  fi
}

confirm_text() {
  local expected="$1"
  local prompt="$2"
  local answer=""
  printf '%s\n' "$prompt"
  read -r answer
  if [ "$answer" != "$expected" ]; then
    fail "Bestaetigung fehlgeschlagen. Erwartet war: $expected"
  fi
}

show_system_info() {
  log "Systeminformationen"
  lsb_release -a 2>/dev/null || true
  uname -a
  free -h
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,MOUNTPOINTS
}

preflight() {
  require_root
  command -v lsb_release >/dev/null 2>&1 || apt-get update
  if ! grep -qi 'ubuntu' /etc/os-release; then
    fail "Dieses Skript ist fuer Ubuntu Server 24.04 LTS vorgesehen."
  fi
  if ! grep -q '24.04' /etc/os-release; then
    log "Warnung: Es wurde nicht eindeutig Ubuntu 24.04 erkannt. Fortsetzung moeglich."
  fi
  getent hosts github.com >/dev/null || fail "DNS-Aufloesung funktioniert nicht."
  ping -c 2 1.1.1.1 >/dev/null 2>&1 || log "Warnung: ICMP-Test fehlgeschlagen, Installation kann trotzdem funktionieren."
}

install_base_packages() {
  log "Installiere Basispakete."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    software-properties-common unzip jq nano vim htop tree \
    ufw rclone smartmontools vainfo intel-gpu-tools pciutils \
    openssh-server unattended-upgrades
}

configure_time_and_updates() {
  log "Setze Zeitzone und aktiviere automatische Security Updates."
  timedatectl set-timezone "$TIMEZONE"
  timedatectl set-ntp true
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

configure_ssh_and_firewall() {
  log "Konfiguriere SSH und UFW."
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-immich-simple.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
X11Forwarding no
EOF
  systemctl restart ssh || systemctl restart sshd

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  if [ -n "$SSH_LAN_CIDR" ]; then
    ufw allow from "$SSH_LAN_CIDR" to any port 22 proto tcp
  else
    ufw allow OpenSSH
  fi

  ufw allow "${IMMICH_PORT}/tcp"
  ufw --force enable
  ufw status verbose
}

install_docker() {
  log "Installiere Docker Engine aus dem offiziellen Docker Repository."
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  # Hinweis: Zeile ohne fuehrende Leerzeichen schreiben (apt-Quelldatei).
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "${VERSION_CODENAME}" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  if [ -n "${SUDO_USER:-}" ] && id "${SUDO_USER}" >/dev/null 2>&1; then
    usermod -aG docker "${SUDO_USER}"
    log "Benutzer ${SUDO_USER} wurde zur Gruppe docker hinzugefuegt. Neue Anmeldung erforderlich."
  fi

  docker run --rm hello-world >/dev/null
  docker version
  docker compose version
}

root_parent_disk() {
  local root_src pk
  root_src="$(findmnt -n -o SOURCE /)"
  pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 || true)"
  if [ -n "$pk" ]; then
    printf '/dev/%s\n' "$pk"
  else
    printf '%s\n' "$root_src"
  fi
}

select_and_prepare_disks() {
  local root_disk data_disk backup_disk data_uuid backup_uuid
  root_disk="$(root_parent_disk)"

  log "Verfuegbare Datentraeger:"
  lsblk -dpno NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS | grep -v '^/dev/loop' || true
  printf '\nSystemdatentraeger scheint zu sein: %s\n' "$root_disk"
  printf 'Diesen Datentraeger nicht auswaehlen.\n\n'

  read -r -p "Geraet fuer Immich-Produktivdaten eingeben, z.B. /dev/sda: " data_disk
  read -r -p "Geraet fuer lokale Backups eingeben, z.B. /dev/sdb: " backup_disk

  [ -b "$data_disk" ] || fail "Produktivdatentraeger existiert nicht: $data_disk"
  [ -b "$backup_disk" ] || fail "Backupdatentraeger existiert nicht: $backup_disk"
  [ "$data_disk" != "$backup_disk" ] || fail "Daten- und Backupdatentraeger duerfen nicht identisch sein."
  [ "$data_disk" != "$root_disk" ] || fail "Produktivdatentraeger ist der Systemdatentraeger."
  [ "$backup_disk" != "$root_disk" ] || fail "Backupdatentraeger ist der Systemdatentraeger."

  if findmnt -S "$data_disk" >/dev/null 2>&1 || findmnt -S "$backup_disk" >/dev/null 2>&1; then
    fail "Mindestens einer der gewaehlten Datentraeger ist bereits gemountet. Bitte zuerst pruefen."
  fi

  confirm_text "FORMAT $data_disk" "WARNUNG: $data_disk wird vollstaendig geloescht. Zum Fortfahren exakt eingeben: FORMAT $data_disk"
  confirm_text "FORMAT $backup_disk" "WARNUNG: $backup_disk wird vollstaendig geloescht. Zum Fortfahren exakt eingeben: FORMAT $backup_disk"

  log "Erstelle ext4-Dateisysteme."
  wipefs -a "$data_disk"
  wipefs -a "$backup_disk"
  mkfs.ext4 -F -L IMMICH_DATA "$data_disk"
  mkfs.ext4 -F -L IMMICH_BACKUP "$backup_disk"

  data_uuid="$(blkid -s UUID -o value "$data_disk")"
  backup_uuid="$(blkid -s UUID -o value "$backup_disk")"

  mkdir -p "$DATA_MOUNT" "$BACKUP_MOUNT"
  cp /etc/fstab /etc/fstab.bak.$(date +%F_%H%M%S)

  grep -v "${DATA_MOUNT}" /etc/fstab | grep -v "${BACKUP_MOUNT}" >/etc/fstab.tmp
  cat /etc/fstab.tmp >/etc/fstab
  rm -f /etc/fstab.tmp

  cat >>/etc/fstab <<EOF
UUID=${data_uuid} ${DATA_MOUNT} ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2
UUID=${backup_uuid} ${BACKUP_MOUNT} ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2
EOF

  systemctl daemon-reload
  mount -a
  findmnt "$DATA_MOUNT" || fail "Produktivdaten-Mount fehlgeschlagen."
  findmnt "$BACKUP_MOUNT" || fail "Backup-Mount fehlgeschlagen."

  mkdir -p "$DATA_MOUNT/photos" "$DATA_MOUNT/postgres" "$DATA_MOUNT/model-cache"
  mkdir -p "$BACKUP_MOUNT/current" "$BACKUP_MOUNT/versions" \
    "$BACKUP_MOUNT/postgres-dumps" "$BACKUP_MOUNT/compose-backup" "$BACKUP_MOUNT/logs"
}

install_immich_files() {
  log "Erzeuge Immich-Verzeichnisstruktur und Konfigurationsdateien."
  mkdir -p "$APP_DIR/scripts"
  chmod 0750 "$APP_DIR"

  local db_password
  db_password="$(openssl rand -base64 36 | tr -d '=+/ ' | cut -c1-32)"

  cat >"$APP_DIR/.env" <<EOF
# Immich Umgebung fuer Docker Compose
# Diese Datei wird von docker compose gelesen.
TZ=Europe/Berlin
# Auf den Major-Release v2 gepinnt: zieht automatisch alle v2.x-Updates,
# aber KEINEN Sprung auf einen naechsten Major (z. B. v3), der die
# Installation unbemerkt brechen koennte. Bewusstes Major-Upgrade:
# diesen Wert anpassen und vorher das Immich-Changelog lesen.
IMMICH_VERSION=v2
UPLOAD_LOCATION=${DATA_MOUNT}/photos
DB_DATA_LOCATION=${DATA_MOUNT}/postgres
MODEL_CACHE_LOCATION=${DATA_MOUNT}/model-cache
DB_PASSWORD=${db_password}
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
EOF
  chmod 0600 "$APP_DIR/.env"

  cat >"$APP_DIR/docker-compose.yml" <<'EOF'
services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - '2283:2283'
    depends_on:
      redis:
        condition: service_healthy
      database:
        condition: service_healthy
    # /dev/dri wird fuer Hardware-Transcoding (Intel QuickSync) durchgereicht.
    # Bei Rechtefehlern auf renderD128 die Render-Gruppe des Hosts ergaenzen
    # (siehe Handbuch, QuickSync-Troubleshooting): group_add: ["<render-GID>"]
    devices:
      - /dev/dri:/dev/dri
    restart: always
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    # Standard-Image nutzt CPU. /dev/dri wird hier bewusst NICHT durchgereicht,
    # da es ohne das "-openvino"-Image keinen Effekt haette.
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - ${MODEL_CACHE_LOCATION}:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9
    restart: always
    healthcheck:
      test: redis-cli ping || exit 1
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: always
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" || exit 1']
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
}

install_backup_scripts() {
  log "Installiere Backup- und Restore-Skripte."
  cat >"$APP_DIR/scripts/immich-backup.sh" <<'EOF'
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

# Reihenfolge bewusst: zuerst Datenbank, dann Dateien.
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

# Synchronisiert das gesamte UPLOAD_LOCATION inkl. des von Immich erzeugten
# Ordners backups/ mit automatischen DB-Backups.
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
EOF

  cat >"$APP_DIR/scripts/restore-postgres.sh" <<'EOF'
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

# WICHTIG: pg_dumpall setzt den search_path im Dump auf leer. Ohne die folgende
# sed-Korrektur scheitert der Restore an der VectorChord-/pgvector-Erweiterung,
# die Immich zwingend benoetigt. Entspricht der offiziellen Immich-Anleitung.
gunzip -c "$DUMP_FILE" \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker compose exec -T database \
      psql --username="$DB_USERNAME" --dbname=postgres

docker compose up -d
docker compose ps
EOF

  cat >"$APP_DIR/scripts/restore-files.sh" <<'EOF'
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
EOF

  cat >"$APP_DIR/scripts/healthcheck.sh" <<'EOF'
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
EOF

  chmod 0750 "$APP_DIR/scripts/"*.sh
}

install_systemd_units() {
  log "Installiere systemd Timer fuer taegliches Backup."
  cat >/etc/systemd/system/immich-backup.service <<'EOF'
[Unit]
Description=Immich lokales Backup auf zweite HDD
Requires=docker.service
After=docker.service
# Beide HDDs muessen gemountet sein, bevor das Backup startet.
RequiresMountsFor=/mnt/immich-data /mnt/immich-backup

[Service]
Type=oneshot
ExecStart=/opt/immich/scripts/immich-backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  cat >/etc/systemd/system/immich-backup.timer <<'EOF'
[Unit]
Description=Taegliches Immich Backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now immich-backup.timer
}

install_offsite_backup() {
  log "Installiere optionales Offsite-Backup (standardmaessig deaktiviert)."
  cat >"$APP_DIR/scripts/immich-offsite.sh" <<'OFF_EOF'
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
OFF_EOF
  chmod 0750 "$APP_DIR/scripts/immich-offsite.sh"

  cat >"$APP_DIR/offsite.env.template" <<'OFF_ENV'
# Konfiguration fuer das optionale Offsite-Backup (immich-offsite.sh).
# Kopiere diese Datei nach /opt/immich/offsite.env und passe sie an.
#
# OFFSITE_REMOTE = <rclone-remote>:<zielpfad/bucket>
# Beispiele:
#   OFFSITE_REMOTE=offsite:immich-backup
#   OFFSITE_REMOTE=gdrive:Backups/immich
OFFSITE_REMOTE=offsite:immich-backup
OFF_ENV
  chmod 0640 "$APP_DIR/offsite.env.template"

  cat >/etc/systemd/system/immich-offsite.service <<'OFF_SVC'
[Unit]
Description=Immich Offsite-Backup (rclone) ins Cloud-/Remote-Ziel
Requires=docker.service
After=docker.service immich-backup.service
RequiresMountsFor=/mnt/immich-backup

[Service]
Type=oneshot
ExecStart=/opt/immich/scripts/immich-offsite.sh
Nice=15
IOSchedulingClass=best-effort
IOSchedulingPriority=7
OFF_SVC

  cat >/etc/systemd/system/immich-offsite.timer <<'OFF_TMR'
[Unit]
Description=Taegliches Immich Offsite-Backup

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
OFF_TMR

  systemctl daemon-reload
  log "Offsite-Backup vorbereitet, aber NICHT aktiviert. Aktivierung:"
  log "  1) sudo rclone config            (Remote anlegen, z. B. offsite)"
  log "  2) sudo cp $APP_DIR/offsite.env.template $APP_DIR/offsite.env && sudo nano $APP_DIR/offsite.env"
  log "  3) sudo systemctl enable --now immich-offsite.timer"
}

install_remote_access_script() {
  log "Installiere Fernzugriff-Skript (setup-remote-access.sh)."
  cat >"$APP_DIR/scripts/setup-remote-access.sh" <<'SRA_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Interaktive Einrichtung des Fernzugriffs fuer Immich auf dem Dell Wyse 5070.
# Kann direkt vom Bootstrap aufgerufen oder spaeter eigenstaendig ausgefuehrt werden:
#   sudo /opt/immich/scripts/setup-remote-access.sh
#
# Optionen:
#   1) Tailscale                         (empfohlen, kein Portforwarding, kein Upload-Limit)
#   2) DuckDNS + Nginx Proxy Manager     (oeffentlich, Portforwarding noetig, kein Limit)
#   3) Cloudflare DNS + DDNS + NPM        (oeffentlich, Portforwarding noetig, DNS-only -> kein Limit)
#   4) Cloudflare Tunnel                  (kein Portforwarding, ABER 100-MB-Upload-Limit)
#   5) Abbrechen

TIMEZONE="${TIMEZONE:-Europe/Berlin}"
IMMICH_PORT="${IMMICH_PORT:-2283}"
NPM_DIR="/opt/nginx-proxy-manager"
DDNS_DIR="/opt/ddns"
CFD_DIR="/opt/cloudflared"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { printf '[%s] FEHLER: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

require_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || fail "Bitte mit sudo ausfuehren."; }
need_docker()  { command -v docker >/dev/null 2>&1 || fail "Docker ist nicht installiert."; }

server_ip() { hostname -I | awk '{print $1}'; }

open_web_ports() {
  if command -v ufw >/dev/null 2>&1; then
    log "Oeffne Ports 80/tcp und 443/tcp in UFW."
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
}

deploy_npm() {
  log "Installiere Nginx Proxy Manager nach ${NPM_DIR}."
  mkdir -p "${NPM_DIR}/data" "${NPM_DIR}/letsencrypt"
  cat >"${NPM_DIR}/docker-compose.yml" <<'NPMYML'
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx_proxy_manager
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
NPMYML
  ( cd "${NPM_DIR}" && docker compose up -d )
  cat <<EOF

Nginx Proxy Manager laeuft.
  Admin-Oberflaeche:  http://$(server_ip):81
  Standard-Login:     admin@example.com / changeme  (sofort aendern!)

Proxy Host fuer Immich anlegen:
  Domain Names:        deine Domain (z. B. photos.example.org)
  Scheme:              http
  Forward Hostname/IP: $(server_ip)
  Forward Port:        ${IMMICH_PORT}
  Websockets Support:  aktivieren
  Block Common Exploits: aktivieren
  SSL-Reiter:          Let's-Encrypt-Zertifikat anfordern, Force SSL + HTTP/2 aktivieren

WICHTIG: Port 81 (Admin) NICHT am Router freigeben.
EOF
}

router_hint_ports() {
  cat <<EOF

Router-Schritte (Vodafone Station):
  - Portfreigabe TCP 80  -> $(server_ip)
  - Portfreigabe TCP 443 -> $(server_ip)
  - Port 81 NICHT freigeben.
  - Da die Vodafone Station deinen DDNS-Anbieter nicht direkt unterstuetzt,
    wird die DNS-Aktualisierung vom Container auf diesem Server uebernommen.
    Die DynDNS-Funktion der Vodafone Station bleibt ungenutzt/deaktiviert.
EOF
}

setup_tailscale() {
  log "Richte Tailscale ein."
  if ! command -v tailscale >/dev/null 2>&1; then
    # Bevorzugt der offizielle Installer: erkennt Distribution und Codename
    # automatisch (Ubuntu, Debian, Raspberry Pi OS usw.).
    if ! curl -fsSL https://tailscale.com/install.sh | sh; then
      log "Offizieller Installer fehlgeschlagen, nutze distro-spezifische Paketquelle."
      . /etc/os-release
      local repo codename
      case "${ID:-}:${ID_LIKE:-}" in
        raspbian:*|*raspbian*) repo="raspbian" ;;
        ubuntu:*|*ubuntu*)     repo="ubuntu" ;;
        *)                     repo="debian" ;;
      esac
      codename="${VERSION_CODENAME:-noble}"
      install -d -m 0755 /usr/share/keyrings
      curl -fsSL "https://pkgs.tailscale.com/stable/${repo}/${codename}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
      # Hinweis: korrekte Listendatei heisst <codename>.tailscale-keyring.list
      curl -fsSL "https://pkgs.tailscale.com/stable/${repo}/${codename}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
    fi
  fi
  command -v tailscale >/dev/null 2>&1 || fail "Tailscale-Installation fehlgeschlagen."
  systemctl enable --now tailscaled 2>/dev/null || true
  log "Starte 'tailscale up'. Den angezeigten Link im Browser bestaetigen."
  tailscale up
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  cat <<EOF

Tailscale ist aktiv.
  Tailscale-IP dieses Servers: ${ts_ip:-<siehe: tailscale ip -4>}

Naechste Schritte:
  1. Tailscale-App auf iPhone/Android installieren, gleiches Konto, einloggen.
  2. In der Immich-App die Server-URL setzen:
       http://${ts_ip:-<tailscale-ip>}:${IMMICH_PORT}
  3. Optional MagicDNS im Tailscale-Admin aktivieren (Name statt IP).
  4. Tipp: In der Immich-App zwei URLs hinterlegen - lokal die LAN-IP,
     unterwegs die Tailscale-IP (automatischer Wechsel).

Kein Portforwarding noetig, kein Upload-Limit. Der Server bleibt nicht oeffentlich erreichbar.
EOF
}

setup_duckdns() {
  log "Richte DuckDNS-Updater + Nginx Proxy Manager ein."
  local sub token
  read -r -p "DuckDNS-Subdomain (ohne .duckdns.org), z. B. meinimmich: " sub
  read -r -s -p "DuckDNS-Token: " token; echo
  [ -n "$sub" ] && [ -n "$token" ] || fail "Subdomain und Token sind erforderlich."

  mkdir -p "${DDNS_DIR}"
  umask 077
  cat >"${DDNS_DIR}/.env" <<EOF
DUCKDNS_SUBDOMAINS=${sub}
DUCKDNS_TOKEN=${token}
EOF
  chmod 600 "${DDNS_DIR}/.env"
  cat >"${DDNS_DIR}/docker-compose.yml" <<DUCKYML
services:
  duckdns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: duckdns
    restart: unless-stopped
    environment:
      - TZ=${TIMEZONE}
      - SUBDOMAINS=\${DUCKDNS_SUBDOMAINS}
      - TOKEN=\${DUCKDNS_TOKEN}
      - UPDATE_IP=ipv4
      - LOG_FILE=false
DUCKYML
  ( cd "${DDNS_DIR}" && docker compose up -d )
  log "DuckDNS-Updater laeuft. Deine Adresse: ${sub}.duckdns.org"
  open_web_ports
  deploy_npm
  router_hint_ports
  cat <<EOF

In der Immich-App als Server-URL eintragen (nach SSL in NPM):
  https://${sub}.duckdns.org
EOF
}

setup_cloudflare_dns() {
  log "Richte Cloudflare-DDNS (DNS-only) + Nginx Proxy Manager ein."
  echo "Voraussetzung: Deine Domain wird bereits ueber Cloudflare verwaltet."
  echo "Erstelle in Cloudflare einen API-Token mit der Vorlage 'Edit zone DNS' (nur diese Zone)."
  local token domains
  read -r -s -p "Cloudflare API-Token: " token; echo
  read -r -p "Domain(s), kommagetrennt, z. B. photos.example.org: " domains
  [ -n "$token" ] && [ -n "$domains" ] || fail "Token und Domain sind erforderlich."

  mkdir -p "${DDNS_DIR}"
  umask 077
  cat >"${DDNS_DIR}/.env" <<EOF
CLOUDFLARE_API_TOKEN=${token}
CF_DOMAINS=${domains}
EOF
  chmod 600 "${DDNS_DIR}/.env"
  cat >"${DDNS_DIR}/docker-compose.yml" <<CFDNSYML
services:
  cloudflare-ddns:
    image: favonia/cloudflare-ddns:1
    container_name: cloudflare_ddns
    network_mode: host
    restart: always
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - all
    read_only: true
    environment:
      - CLOUDFLARE_API_TOKEN=\${CLOUDFLARE_API_TOKEN}
      - DOMAINS=\${CF_DOMAINS}
      - PROXIED=false
CFDNSYML
  ( cd "${DDNS_DIR}" && docker compose up -d )
  open_web_ports
  deploy_npm
  router_hint_ports
  cat <<EOF

WICHTIG fuer grosse Uploads:
  - Der DNS-Eintrag muss in Cloudflare auf "DNS only" (graue Wolke) stehen,
    damit der Verkehr NICHT durch den Cloudflare-Proxy laeuft (sonst 100-MB-Limit).
  - PROXIED=false ist im Container bereits gesetzt.

In der Immich-App als Server-URL eintragen (nach SSL in NPM):
  https://<deine-domain>
EOF
}

setup_cloudflare_tunnel() {
  cat <<'EOF'

ACHTUNG - Cloudflare Tunnel und Uploads:
  Cloudflare Free begrenzt einzelne Uploads auf 100 MB. Fuer das Sichern
  grosser Videos von unterwegs ist dieser Weg NICHT zuverlaessig.
  Empfehlung fuer Backup von unterwegs: Tailscale (Option 1) oder DuckDNS/
  Cloudflare-DNS mit Reverse Proxy (Option 2/3).
  Cloudflare Tunnel eignet sich gut zum reinen ANSEHEN von unterwegs.
EOF
  read -r -p "Trotzdem Cloudflare Tunnel einrichten? (ja/nein): " yn
  [ "$yn" = "ja" ] || { log "Cloudflare Tunnel uebersprungen."; return 0; }

  echo "Erstelle im Cloudflare Zero Trust Dashboard einen Tunnel und kopiere den Tunnel-Token."
  local token
  read -r -s -p "Cloudflare Tunnel-Token: " token; echo
  [ -n "$token" ] || fail "Tunnel-Token ist erforderlich."

  mkdir -p "${CFD_DIR}"
  umask 077
  cat >"${CFD_DIR}/.env" <<EOF
TUNNEL_TOKEN=${token}
EOF
  chmod 600 "${CFD_DIR}/.env"
  cat >"${CFD_DIR}/docker-compose.yml" <<CFTYML
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    network_mode: host
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=\${TUNNEL_TOKEN}
CFTYML
  ( cd "${CFD_DIR}" && docker compose up -d )
  cat <<EOF

Cloudflared laeuft. Letzte Schritte im Cloudflare Zero Trust Dashboard:
  - Tunnel -> Public Hostname hinzufuegen:
      Subdomain/Domain: deine Wunschadresse
      Service:          http://localhost:${IMMICH_PORT}
  - Kein Portforwarding noetig; der Tunnel ist ausgehend.

In der Immich-App:
  - Zum ANSEHEN von unterwegs: https://<deine-cloudflare-domain>
  - Zum HOCHLADEN: lokale LAN-URL (zu Hause) oder Tailscale verwenden.
EOF
}

main() {
  require_root
  need_docker
  cat <<EOF

=== Immich Fernzugriff einrichten ===
Waehle eine Option:
  1) Tailscale (empfohlen - kein Portforwarding, kein Upload-Limit)
  2) DuckDNS + Nginx Proxy Manager (oeffentlich, Portforwarding noetig)
  3) Cloudflare DNS + DDNS + Nginx Proxy Manager (oeffentlich, Portforwarding noetig)
  4) Cloudflare Tunnel (kein Portforwarding, ABER 100-MB-Upload-Limit)
  5) Abbrechen
EOF
  local choice
  read -r -p "Auswahl [1-5]: " choice
  case "$choice" in
    1) setup_tailscale ;;
    2) setup_duckdns ;;
    3) setup_cloudflare_dns ;;
    4) setup_cloudflare_tunnel ;;
    5) log "Abgebrochen. Kein Fernzugriff eingerichtet."; exit 0 ;;
    *) fail "Ungueltige Auswahl." ;;
  esac
  log "Fernzugriff-Einrichtung abgeschlossen."
}

main "$@"
SRA_EOF
  chmod 0750 "$APP_DIR/scripts/setup-remote-access.sh"
}

setup_remote_access() {
  cat <<'EOF'

Optional: Fernzugriff (Backup/Ansehen von unterwegs) einrichten.
  - Tailscale (empfohlen): kein Portforwarding, kein Upload-Limit
  - DuckDNS/Cloudflare + Reverse Proxy: oeffentlich, Portforwarding noetig
  - Cloudflare Tunnel: kein Portforwarding, aber 100-MB-Upload-Limit
EOF
  local yn
  read -r -p "Fernzugriff jetzt einrichten? (ja/nein): " yn
  if [ "$yn" = "ja" ]; then
    TIMEZONE="$TIMEZONE" IMMICH_PORT="$IMMICH_PORT" "$APP_DIR/scripts/setup-remote-access.sh"
  else
    log "Spaeter ausfuehrbar mit: sudo $APP_DIR/scripts/setup-remote-access.sh"
  fi
}

start_immich() {
  log "Starte Immich."
  cd "$APP_DIR"
  docker compose pull
  docker compose up -d
  docker compose ps
}

quicksync_check() {
  log "Pruefe Intel QuickSync / VAAPI grob."
  if [ -d /dev/dri ]; then
    ls -la /dev/dri
    vainfo || log "vainfo meldet Fehler. QuickSync kann trotzdem nach Treiber-/Rechtepruefung funktionieren."
  else
    log "WARNUNG: /dev/dri existiert nicht. Hardwarebeschleunigung ist nicht verfuegbar."
  fi
}

final_notes() {
  local ip
  ip="$(hostname -I | awk '{print $1}')"
  cat <<EOF

Installation abgeschlossen.

Immich lokal oeffnen:
  http://${ip}:${IMMICH_PORT}

Wichtige Befehle:
  cd /opt/immich && sudo docker compose ps
  sudo systemctl status immich-backup.timer
  sudo systemctl start immich-backup.service
  sudo /opt/immich/scripts/healthcheck.sh

Hinweis:
  Wenn der angemeldete Benutzer zur Docker-Gruppe hinzugefuegt wurde,
  ist fuer docker ohne sudo eine neue Anmeldung erforderlich.
EOF
}

main() {
  preflight
  show_system_info
  install_base_packages
  configure_time_and_updates
  configure_ssh_and_firewall
  install_docker
  select_and_prepare_disks
  install_immich_files
  install_backup_scripts
  install_systemd_units
  install_offsite_backup
  install_remote_access_script
  quicksync_check
  start_immich
  setup_remote_access
  final_notes
}

main "$@"
