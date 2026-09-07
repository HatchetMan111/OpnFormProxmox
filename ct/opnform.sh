#!/usr/bin/env bash
# OpnForm – Community-Scripts-Core-Variante (ct/).
# Alternative zum standalone Einzeiler install/opnform.sh: nutzt build.func vom
# community-scripts/core. Auf dem Proxmox-Host ausführen:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpnFormProxmox/main/ct/opnform.sh)"
_CS_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
# shellcheck disable=SC1090,SC1091
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2026 – License: MIT
# Source: https://opnform.com/ | Github: https://github.com/OpnForm/OpnForm

APP="opnform"
var_tags="${var_tags:-forms}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /usr/local/bin/opnform-install.sh ]]; then
    msg_error "Keine OpnForm-Installation gefunden!"
    exit
  fi
  msg_info "Aktualisiere OpnForm (idempotent: pull + up + migrate)"
  bash /usr/local/bin/opnform-install.sh
  msg_ok "Aktualisiert."
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:80${CL}"
