#!/usr/bin/env bash
#
# OpnForm für Proxmox VE – Host-Installer im Community-Scripts-Stil.
#
# Einzeiler (auf dem Proxmox-Host als root ausführen):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/install/opnform.sh)"
#
# Was das Script tut:
#   1. Prüft Proxmox-Host (root, pveversion, pct, Storage, Template).
#   2. Erstellt einen LXC-Container (idempotent: vorhandene CTID wird wiederverwendet).
#   3. Schiebt install/opnform-install.sh in den Container und führt es dort aus
#      (Docker + OpnForm-Stack via offiziellem docker-compose.yml).
#   4. Verifiziert und gibt die finale URL http://[LXC-IP]:80 aus.
#
# Debugging:
#   DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/install/opnform.sh)"
#   Bei Fehlern gibt der ERR-Trap unten die KOMPLETTE Kette aus
#   (Exit-Code, fehlgeschlagenes Kommando, Zeile, Stack, pct-Status).
#
# Lizenz: MIT

set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – per Env überschreibbar)
# ---------------------------------------------------------------------------
APP="${APP:-opnform}"
REPO="${REPO:-HatchetMan111/OpnFormProxmox}"
BRANCH="${BRANCH:-main}"
GUEST_SCRIPT_URL="${GUEST_SCRIPT_URL:-https://raw.githubusercontent.com/${REPO}/${BRANCH}/install/opnform-install.sh}"

CTID="${CTID:-}"                       # leer = automatisch via pvesh nextid
HOSTNAME="${HOSTNAME:-opnform}"
CPU="${CPU:-2}"                        # OpnForm-Minimum: 2 (empfohlen 4 bei vielen Forms)
RAM="${RAM:-4096}"                     # MB – 2 GB ist zu wenig (Postgres+Redis+Node), Minimum 4096
DISK="${DISK:-12}"                     # GB für rootfs
STORAGE="${STORAGE:-local-lvm}"        # Storage für rootfs
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"   # Storage für CT-Templates
BRIDGE="${BRIDGE:-vmbr0}"
IP_MODE="${IP_MODE:-dhcp}"             # "dhcp" oder statische CIDR, z. B. "192.168.1.50/24"
GATEWAY="${GATEWAY:-}"                 # nur bei statischer IP nötig
DNS="${DNS:-}"                         # optional, z. B. "192.168.1.1"
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
WEB_PORT="${WEB_PORT:-80}"
OVERWRITE="${OVERWRITE:-0}"            # 1 = vorhandenen Container löschen + neu erstellen
DEBUG="${DEBUG:-0}"

# ---------------------------------------------------------------------------
# Helpers (Farben + Logging wie Community Scripts: msg_info / msg_ok / msg_error)
# ---------------------------------------------------------------------------
if [[ "${DEBUG}" == "1" ]]; then
  set -x
fi

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
msg_info()  { echo -e "${YW} • INFO: $*${CL}"; }
msg_ok()    { echo -e "${GN} • OK: $*${CL}"; }
msg_error() { echo -e "${RD} • FEHLER: $*${CL}" >&2; }

# Komplette Fehlermeldungskette – niemals nur die letzte Zeile.
err_trap() {
  local ec=$?
  local cmd="${BASH_COMMAND:-unbekannt}"
  msg_error "Installationsfehler (Exit-Code ${ec})"
  echo "  Fehlgeschlagenes Kommando : ${cmd}" >&2
  echo "  Zeile                     : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-?}}" >&2
  echo "  Stacktrace:" >&2
  local i
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    echo "    #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]:-?}:${BASH_LINENO[$((i - 1))]:-?}" >&2
  done
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]] && pct status "${CTID}" >/dev/null 2>&1; then
    echo "  Container-Status:" >&2
    pct status "${CTID}" 2>&1 | sed 's/^/    /' >&2 || true
  fi
  echo "  Re-Run mit Debug-Log:" >&2
  echo "    DEBUG=1 bash -x -c \"\$(wget -qLO - https://raw.githubusercontent.com/${REPO}/${BRANCH}/install/opnform.sh)\" 2>&1 | tee /tmp/opnform-install-debug.log" >&2
  exit "${ec}"
}
trap err_trap ERR

check_host() {
  msg_info "Prüfe Proxmox-Host …"
  [[ "$(id -u)" -eq 0 ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
  command -v pveversion >/dev/null || { msg_error "pveversion nicht gefunden – kein Proxmox-Host?"; exit 1; }
  command -v pct >/dev/null || { msg_error "pct nicht gefunden."; exit 1; }
  command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
  msg_ok "Host: $(pveversion | head -1)"
}

pick_ctid() {
  if [[ -z "${CTID}" ]]; then
    CTID="$(pvesh get /cluster/nextid)"
    msg_info "Automatische CT-ID: ${CTID}"
  else
    msg_info "Gewünschte CT-ID: ${CTID}"
  fi
}

container_exists() { pct status "$1" >/dev/null 2>&1; }

ensure_template() {
  msg_info "Prüfe LXC-Template ${TEMPLATE} auf Storage ${TEMPLATE_STORAGE} …"
  if pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE}"; then
    msg_ok "Template bereits vorhanden."
    return
  fi
  msg_info "Lade Template herunter (pveam update + download) …"
  pveam update
  # Falls exakter Dateiname nicht mehr existiert, neuestes debian-12-standard nehmen.
  local tpl="${TEMPLATE}"
  if ! pveam available --section system 2>/dev/null | grep -q "${tpl}"; then
    tpl="$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard[^ ]*\.tar\.zst' | sort -V | tail -1)"
    [[ -n "${tpl}" ]] || { msg_error "Kein debian-12 Template auf dem Mirror gefunden."; exit 1; }
    TEMPLATE="${tpl}"
    msg_info "Verwende stattdessen: ${TEMPLATE}"
  fi
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
  msg_ok "Template bereit: ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
}

create_or_reuse_container() {
  if container_exists "${CTID}"; then
    if [[ "${OVERWRITE}" == "1" ]]; then
      msg_info "OVERWRITE=1 – lösche vorhandenen Container ${CTID} …"
      pct stop "${CTID}" 2>/dev/null || true
      sleep 2
      pct destroy "${CTID}"
      msg_ok "Alter Container gelöscht."
    else
      msg_info "Container ${CTID} existiert – wird wiederverwendet (idempotent, kein Neuaufbau)."
      pct set "${CTID}" --onboot 1
      pct set "${CTID}" --features nesting=1,keyctl=1
      return
    fi
  fi

  local net0="name=eth0,bridge=${BRIDGE},ip=${IP_MODE}"
  if [[ "${IP_MODE}" != "dhcp" && -n "${GATEWAY}" ]]; then
    net0="${net0},gw=${GATEWAY}"
  fi
  local ns_args=()
  [[ -n "${DNS}" ]] && ns_args=(--nameserver "${DNS}")

  msg_info "Erstelle LXC ${CTID} (${HOSTNAME}, ${CPU} vCPU, ${RAM} MB RAM, ${DISK} GB Disk) …"
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CPU}" \
    --memory "${RAM}" \
    --swap 512 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "${net0}" \
    --onboot 1 \
    --start 0 \
    --unprivileged "${UNPRIVILEGED}" \
    --features nesting=1,keyctl=1 \
    --timezone "${TIMEZONE}" \
    "${ns_args[@]:-}"
  msg_ok "Container ${CTID} erstellt (onboot=1, nesting=1)."
}

start_and_wait() {
  local status
  status="$(pct status "${CTID}" | awk '{print $2}')"
  if [[ "${status}" != "running" ]]; then
    msg_info "Starte Container ${CTID} …"
    pct start "${CTID}"
  fi
  msg_info "Warte auf Gast-OS (max. 120 s) …"
  local i
  for ((i = 0; i < 24; i++)); do
    if pct exec "${CTID}" -- true >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  pct exec "${CTID}" -- true || { msg_error "Container antwortet nicht auf pct exec."; exit 1; }
  msg_ok "Container läuft."
}

get_container_ip() {
  local ip=""
  local i
  for ((i = 0; i < 24; i++)); do
    ip="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "${ip}" ]] && break
    sleep 5
  done
  [[ -n "${ip}" ]] || { msg_error "Keine Container-IP ermittelbar (DHCP?). Prüfe Bridge/DHCP."; exit 1; }
  echo "${ip}"
}

run_guest_installer() {
  local guest_ip="$1"
  local tmp="/tmp/opnform-install.${CTID}.sh"
  msg_info "Lade Guest-Installer von ${GUEST_SCRIPT_URL} …"
  wget -qO "${tmp}" "${GUEST_SCRIPT_URL}"
  [[ -s "${tmp}" ]] || { msg_error "Download des Guest-Installers fehlgeschlagen."; exit 1; }
  bash -n "${tmp}"
  pct push "${CTID}" "${tmp}" /usr/local/bin/opnform-install.sh
  pct exec "${CTID}" -- chmod +x /usr/local/bin/opnform-install.sh
  msg_info "Führe Installation im Container aus (dauert mehrere Minuten) …"
  # APP_URL aus Container-IP ableiten; explizites APP_URL-Env hat Vorrang.
  pct exec "${CTID}" -- env \
    "APP_URL=${APP_URL:-http://${guest_ip}:${WEB_PORT}}" \
    "WEB_PORT=${WEB_PORT}" \
    "DEBUG=${DEBUG}" \
    bash /usr/local/bin/opnform-install.sh
  msg_ok "Installation im Container abgeschlossen."
}

main() {
  check_host
  pick_ctid
  ensure_template
  create_or_reuse_container
  start_and_wait
  local ip
  ip="$(get_container_ip)"
  msg_ok "Container-IP: ${ip}"
  run_guest_installer "${ip}"

  echo ""
  msg_ok "OpnForm-Setup erfolgreich abgeschlossen!"
  echo -e "  Web UI      : ${GN}http://${ip}:${WEB_PORT}${CL}"
  echo -e "  Container   : CT ${CTID} (${HOSTNAME}) – onboot=1, nesting=1"
  echo -e "  Update      : Script erneut ausführen (idempotent) oder im LXC: bash /usr/local/bin/opnform-install.sh"
  echo -e "  Logs im LXC : journalctl -u opnform --no-pager | tail -50 ; docker logs opnform-api 2>&1 | tail -50"
  echo -e "  Deinstall   : pct stop ${CTID} && pct destroy ${CTID}"
}

main "$@"
