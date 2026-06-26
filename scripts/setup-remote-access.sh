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
