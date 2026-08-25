#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-4pluspainel}"
APP_DIR="${APP_DIR:-/opt/4pluspainel}"
REPO_URL="${REPO_URL:-https://github.com/Alefsousa5/4pluspainel-.git}"
BRANCH="${BRANCH:-arena/01a039e9-4pluspainel}"
APP_USER="${APP_USER:-www-data}"

log() {
  printf '\033[1;34m[4pluspainel]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  die "Execute como root: sudo bash ${APP_DIR}/scripts/update-ubuntu.sh"
fi

[[ -d "${APP_DIR}/.git" ]] || die "Repositório não encontrado em ${APP_DIR}."

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

if id "${APP_USER}" >/dev/null 2>&1; then
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
fi

log "Reiniciando serviço ${APP_NAME}..."
systemctl restart "${APP_NAME}"
systemctl --no-pager --full status "${APP_NAME}" || true

log "Atualização concluída."
