#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-4pluspainel}"
APP_DIR="${APP_DIR:-/opt/4pluspainel}"
DATA_DIR="${DATA_DIR:-/var/lib/${APP_NAME}}"
REPO_URL="${REPO_URL:-https://github.com/Alefsousa5/4pluspainel-.git}"
BRANCH="${BRANCH:-arena/01a039e9-4pluspainel}"
APP_USER="${APP_USER:-www-data}"
SSH_HELPER_PATH="${SSH_HELPER_PATH:-/usr/local/sbin/${APP_NAME}-ssh-helper}"
ENABLE_SYSTEM_SSH="${ENABLE_SYSTEM_SSH:-true}"

log() {
  printf '\033[1;34m[4pluspainel]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[aviso]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2
  exit 1
}

get_env_value() {
  local key="$1"
  local env_file="${APP_DIR}/.env"

  if [[ -f "${env_file}" ]]; then
    grep -E "^${key}=" "${env_file}" | tail -n 1 | cut -d= -f2- || true
  fi
}

read_env_if_exists() {
  local value

  value="$(get_env_value DATA_DIR)"
  [[ -n "${value}" ]] && DATA_DIR="${value}"

  value="$(get_env_value SSH_HELPER)"
  [[ -n "${value}" ]] && SSH_HELPER_PATH="${value}"

  value="$(get_env_value ENABLE_SYSTEM_SSH)"
  [[ -n "${value}" ]] && ENABLE_SYSTEM_SSH="${value}"

  value="$(get_env_value GIT_REPO)"
  [[ -n "${value}" ]] && REPO_URL="${value}"

  value="$(get_env_value GIT_BRANCH)"
  [[ -n "${value}" ]] && BRANCH="${value}"
}

install_ssh_helper() {
  if [[ "${ENABLE_SYSTEM_SSH}" != "true" ]]; then
    warn "Provisionamento local SSH está desativado. Helper não será reinstalado."
    return
  fi

  if [[ -f "${APP_DIR}/scripts/ssh-helper.sh" ]]; then
    log "Atualizando helper SSH em ${SSH_HELPER_PATH}..."
    install -m 0750 -o root -g root "${APP_DIR}/scripts/ssh-helper.sh" "${SSH_HELPER_PATH}"

    local sudoers_file="/etc/sudoers.d/${APP_NAME}-ssh-helper"
    cat > "${sudoers_file}" <<SUDOERS
# Permite que o serviço do 4G Plus SSH Painel execute apenas o helper de usuários SSH.
${APP_USER} ALL=(root) NOPASSWD: ${SSH_HELPER_PATH} *
SUDOERS
    chmod 0440 "${sudoers_file}"
    visudo -cf "${sudoers_file}" >/dev/null
  fi
}

prepare_permissions() {
  log "Ajustando permissões..."
  mkdir -p "${DATA_DIR}"
  if id "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_USER}" "${DATA_DIR}"
  fi
  chmod 0750 "${DATA_DIR}"

  chown -R root:root "${APP_DIR}"
  find "${APP_DIR}" -type d -exec chmod 0755 {} \;
  find "${APP_DIR}" -type f -exec chmod 0644 {} \;
  chmod +x "${APP_DIR}/scripts/"*.sh
  [[ -f "${APP_DIR}/.env" ]] && chmod 0600 "${APP_DIR}/.env"
}

if [[ "${EUID}" -ne 0 ]]; then
  die "Execute como root: sudo bash ${APP_DIR}/scripts/update-ubuntu.sh"
fi

[[ -d "${APP_DIR}/.git" ]] || die "Repositório não encontrado em ${APP_DIR}."
read_env_if_exists

git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${APP_DIR}" \
  || git config --global --add safe.directory "${APP_DIR}" 2>/dev/null \
  || true

log "Atualizando ${APP_DIR} a partir de ${REPO_URL} (${BRANCH})..."
git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
git -C "${APP_DIR}" fetch --prune origin "${BRANCH}"
git -C "${APP_DIR}" checkout -B "${BRANCH}" "origin/${BRANCH}"
git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"

log "Instalando dependências..."
cd "${APP_DIR}"
if [[ -f package-lock.json ]]; then
  npm ci --omit=dev --no-audit --no-fund
else
  npm install --omit=dev --no-audit --no-fund
fi

install_ssh_helper
prepare_permissions

log "Reiniciando serviço ${APP_NAME}..."
systemctl restart "${APP_NAME}"
systemctl --no-pager --full status "${APP_NAME}" || true

log "Atualização concluída."
