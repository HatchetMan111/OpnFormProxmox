#!/usr/bin/env bash
#
# OpnForm – Guest-Installer (läuft IM LXC-Container, Debian 12).
#
# Wird vom Host-Script install/opnform.sh per pct push + pct exec aufgerufen,
# kann aber auch direkt im Container erneut laufen (idempotent = Update-Pfad):
#   bash /usr/local/bin/opnform-install.sh
#
# Stack (offiziell, via Docker Compose von OpnForm/OpnForm):
#   api (Laravel, jhumanj/opnform-api) + ui (Nuxt, jhumanj/opnform-client)
#   + db (postgres:16) + redis:7 + ingress (nginx, Port 80)
#
# Reboot-sicher:
#   - docker-compose.override.yml mit restart: unless-stopped
#   - systemd-Unit opnform.service (After docker + network-online, enable)
#
# Debugging: DEBUG=1 bash -x /usr/local/bin/opnform-install.sh 2>&1 | tee /tmp/opnform-debug.log
# Lizenz: MIT

set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben)
# ---------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/opt/opnform}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/OpnForm/OpnForm}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
COMPOSE_URL="${COMPOSE_URL:-${UPSTREAM_REPO}/raw/${UPSTREAM_BRANCH}/docker-compose.yml}"
NGINX_URL="${NGINX_URL:-${UPSTREAM_REPO}/raw/${UPSTREAM_BRANCH}/docker/nginx.conf}"
WEB_PORT="${WEB_PORT:-80}"
APP_URL="${APP_URL:-http://localhost:${WEB_PORT}}"
DB_DATABASE="${DB_DATABASE:-forge}"
DB_USERNAME="${DB_USERNAME:-forge}"
DEBUG="${DEBUG:-0}"

if [[ "${DEBUG}" == "1" ]]; then
  set -x
fi

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
msg_info()  { echo -e "${YW} • INFO: $*${CL}"; }
msg_ok()    { echo -e "${GN} • OK: $*${CL}"; }
msg_error() { echo -e "${RD} • FEHLER: $*${CL}" >&2; }

# Volle Fehlerkette: Exit-Code, Kommando, Zeile, Stack, Service- + Container-Logs.
dump_failure() {
  local ec=$?
  local cmd="${BASH_COMMAND:-unbekannt}"
  msg_error "Guest-Installation fehlgeschlagen (Exit-Code ${ec})"
  echo "  Kommando : ${cmd}" >&2
  echo "  Zeile    : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-?}}" >&2
  echo "  Stacktrace:" >&2
  local i
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    echo "    #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]:-?}:${BASH_LINENO[$((i - 1))]:-?}" >&2
  done
  echo "  ---- systemctl status opnform ----" >&2
  systemctl status opnform --no-pager 2>&1 | tail -30 | sed 's/^/  /' >&2 || true
  echo "  ---- journalctl -u opnform (tail) ----" >&2
  journalctl -u opnform --no-pager 2>&1 | tail -40 | sed 's/^/  /' >&2 || true
  if command -v docker >/dev/null 2>&1 && [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    echo "  ---- docker compose ps ----" >&2
    docker compose -f "${APP_DIR}/docker-compose.yml" ps 2>&1 | sed 's/^/  /' >&2 || true
    for c in opnform-api opnform-client opnform-db opnform-redis opnform-ingress; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${c}"; then
        echo "  ---- docker logs ${c} (tail) ----" >&2
        docker logs "${c}" 2>&1 | tail -30 | sed 's/^/  /' >&2 || true
      fi
    done
  fi
  echo "  Debug-Re-Run: DEBUG=1 bash -x /usr/local/bin/opnform-install.sh 2>&1 | tee /tmp/opnform-debug.log" >&2
  exit "${ec}"
}
trap dump_failure ERR

rand_secret() { openssl rand -hex 32; }

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker + Compose bereits installiert: $(docker --version), $(docker compose version --short)"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi
  msg_info "Installiere Docker + Compose-Plugin (Debian 12) …"
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version
  msg_ok "Docker installiert."
}

fetch_stack_files() {
  msg_info "Lege Stack-Dateien in ${APP_DIR} an (idempotent) …"
  mkdir -p "${APP_DIR}/api" "${APP_DIR}/client" "${APP_DIR}/docker"
  if [[ ! -s "${APP_DIR}/docker-compose.yml" ]]; then
    wget -qO "${APP_DIR}/docker-compose.yml" "${COMPOSE_URL}"
  else
    msg_info "docker-compose.yml existiert – Upstream-Refresh …"
    wget -qO "${APP_DIR}/docker-compose.yml" "${COMPOSE_URL}"
  fi
  wget -qO "${APP_DIR}/docker/nginx.conf" "${NGINX_URL}"
  # Reboot-sicherheit auch ohne systemd: alle Services starten neu.
  cat >"${APP_DIR}/docker-compose.override.yml" <<'EOF'
services:
  api: { restart: unless-stopped }
  api-worker: { restart: unless-stopped }
  api-scheduler: { restart: unless-stopped }
  ui: { restart: unless-stopped }
  redis: { restart: unless-stopped }
  db: { restart: unless-stopped }
  ingress: { restart: unless-stopped }
EOF
  msg_ok "Stack-Dateien bereit."
}

write_env_files() {
  # api/.env: Secrets nur beim ersten Lauf erzeugen, danach bewahren (idempotent).
  if [[ ! -s "${APP_DIR}/api/.env" ]]; then
    msg_info "Erzeuge ${APP_DIR}/api/.env mit frischen Secrets …"
    local db_pass app_key jwt_secret front_secret
    db_pass="$(rand_secret | head -c 24)"
    app_key="base64:$(openssl rand -base64 32)"
    jwt_secret="$(rand_secret)"
    front_secret="$(rand_secret)"
    cat >"${APP_DIR}/api/.env" <<EOF
APP_NAME="OpnForm"
APP_ENV=production
APP_DEBUG=false
APP_URL=${APP_URL}
FRONT_URL=${APP_URL}
FRONT_API_SECRET=${front_secret}
APP_KEY=${app_key}
JWT_SECRET=${jwt_secret}
DB_CONNECTION=pgsql
DB_HOST=db
DB_PORT=5432
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${db_pass}
REDIS_HOST=redis
REDIS_PORT=6379
CACHE_STORE=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
TRUSTED_PROXIES=
EOF
    chmod 600 "${APP_DIR}/api/.env"
  else
    msg_info "api/.env existiert – aktualisiere nur URLs (Secrets bleiben) …"
    sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" "${APP_DIR}/api/.env"
    sed -i "s|^FRONT_URL=.*|FRONT_URL=${APP_URL}|" "${APP_DIR}/api/.env"
  fi

  # client/.env: muss FRONT_API_SECRET aus api/.env spiegeln.
  local front_secret
  front_secret="$(grep -E '^FRONT_API_SECRET=' "${APP_DIR}/api/.env" | cut -d= -f2-)"
  cat >"${APP_DIR}/client/.env" <<EOF
NUXT_PUBLIC_APP_URL=${APP_URL}
NUXT_PUBLIC_API_BASE=${APP_URL}/api
NUXT_API_SECRET=${front_secret}
NUXT_PUBLIC_ENV=production
EOF
  msg_ok ".env-Dateien geschrieben (APP_URL=${APP_URL})."
}

install_systemd_unit() {
  msg_info "Installiere systemd-Unit opnform.service …"
  cat >/etc/systemd/system/opnform.service <<EOF
[Unit]
Description=OpnForm Docker Stack (Proxmox LXC)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml stop
ExecReload=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml up -d

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable opnform
  msg_ok "systemd-Unit installiert + enabled (Restart via unless-stopped + oneshot up -d)."
}

start_stack() {
  msg_info "Starte OpnForm-Stack (pull + up -d) …"
  cd "${APP_DIR}"
  docker compose pull
  docker compose up -d
  msg_ok "Stack gestartet."
}

run_migrations() {
  msg_info "Führe Laravel-Migrationen aus (best-effort, idempotent) …"
  local i
  for ((i = 0; i < 30; i++)); do
    if docker exec opnform-api php /usr/share/nginx/html/artisan about >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  # Storage-Link + Migrate schlagen bei Re-Run nicht fehl (|| true nur mit Log).
  docker exec opnform-api php /usr/share/nginx/html/artisan storage:link 2>&1 | tail -3 || true
  docker exec opnform-api php /usr/share/nginx/html/artisan migrate --force 2>&1 | tail -10
  msg_ok "Migrationen abgeschlossen."
}

verify() {
  msg_info "Verifiziere Installation …"
  systemctl is-active --quiet docker || { msg_error "docker.service ist nicht active."; systemctl status docker --no-pager; exit 1; }
  systemctl is-active --quiet opnform || systemctl start opnform
  # HTTP-Check auf localhost:WEB_PORT (max. ~5 Min für Erststart/Build).
  local code="" i
  for ((i = 0; i < 60; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WEB_PORT}/" 2>/dev/null || true)"
    if [[ "${code}" =~ ^(200|301|302)$ ]]; then
      break
    fi
    sleep 5
  done
  [[ "${code}" =~ ^(200|301|302)$ ]] || {
    msg_error "Web UI antwortet nicht (letzter HTTP-Code: ${code:-keine Verbindung})."
    docker compose -f "${APP_DIR}/docker-compose.yml" ps
    exit 1
  }
  msg_ok "Service opnform active, Web UI antwortet mit HTTP ${code} auf localhost:${WEB_PORT}."
}

main() {
  install_docker
  fetch_stack_files
  write_env_files
  install_systemd_unit
  start_stack
  run_migrations
  verify
  echo ""
  msg_ok "OpnForm läuft! Web UI: ${APP_URL} (lokal: http://localhost:${WEB_PORT}/)"
}

main "$@"
