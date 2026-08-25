#!/usr/bin/env bash
set -Eeuo pipefail

LIMITS_FILE="${LIMITS_FILE:-/etc/security/limits.d/4pluspainel-ssh.conf}"
SSH_USER_SHELL="${SSH_USER_SHELL:-/bin/bash}"
LOCK_FILE="${LOCK_FILE:-/run/4pluspainel-ssh-helper.lock}"

reserved_users=(
  root admin administrator ubuntu debian centos fedora ec2-user www-data nginx apache daemon bin sys sync games man lp
  mail news uucp proxy backup list irc gnats nobody systemd systemd-network systemd-resolve sshd messagebus polkitd
)

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "${value}"
}

json_ok() {
  local action="$1"
  local username="$2"
  local message="$3"
  printf '{"ok":true,"action":"%s","username":"%s","message":"%s"}\n' \
    "$(json_escape "${action}")" \
    "$(json_escape "${username}")" \
    "$(json_escape "${message}")"
}

json_error() {
  local message="$1"
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "${message}")" >&2
}

fail() {
  json_error "$1"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "execute como root ou via sudo"
}

is_reserved_user() {
  local username="$1"
  local reserved

  for reserved in "${reserved_users[@]}"; do
    if [[ "${username}" == "${reserved}" ]]; then
      return 0
    fi
  done

  return 1
}

validate_username() {
  local username="$1"

  [[ "${username}" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
    || fail "usuário inválido: use 3 a 32 caracteres em minúsculo, números, _ ou -"

  is_reserved_user "${username}" && fail "usuário reservado pelo sistema: ${username}"
}

validate_password() {
  local password="$1"
  [[ "${#password}" -ge 6 && "${#password}" -le 128 ]] || fail "senha precisa ter entre 6 e 128 caracteres"
  [[ "${password}" != *$'\n'* && "${password}" != *$'\r'* && "${password}" != *:* ]] || fail "senha contém caractere inválido"
}

validate_date() {
  local expires="$1"
  [[ "${expires}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "data de expiração inválida, use YYYY-MM-DD"
  date -d "${expires}" +%F >/dev/null 2>&1 || fail "data de expiração inválida"
}

validate_max_connections() {
  local max_connections="$1"
  [[ "${max_connections}" =~ ^[0-9]+$ ]] || fail "limite de conexões inválido"
  (( max_connections >= 1 && max_connections <= 999 )) || fail "limite de conexões deve estar entre 1 e 999"
}

ensure_limits_entry() {
  local username="$1"
  local max_connections="$2"

  mkdir -p "$(dirname "${LIMITS_FILE}")"
  touch "${LIMITS_FILE}"
  chmod 0644 "${LIMITS_FILE}"

  if grep -qE "^${username}[[:space:]]+hard[[:space:]]+maxlogins[[:space:]]+" "${LIMITS_FILE}"; then
    sed -i "s|^${username}[[:space:]]\+hard[[:space:]]\+maxlogins[[:space:]]\+.*|${username} hard maxlogins ${max_connections}|" "${LIMITS_FILE}"
  else
    printf '%s hard maxlogins %s\n' "${username}" "${max_connections}" >> "${LIMITS_FILE}"
  fi
}

remove_limits_entry() {
  local username="$1"

  if [[ -f "${LIMITS_FILE}" ]]; then
    sed -i "/^${username}[[:space:]]\+hard[[:space:]]\+maxlogins[[:space:]]\+/d" "${LIMITS_FILE}"
  fi
}

create_user() {
  local username="$1"
  local password="$2"
  local expires="$3"
  local max_connections="$4"

  validate_username "${username}"
  validate_password "${password}"
  validate_date "${expires}"
  validate_max_connections "${max_connections}"

  if ! getent passwd "${username}" >/dev/null 2>&1; then
    useradd -m -s "${SSH_USER_SHELL}" "${username}"
  fi

  printf '%s:%s\n' "${username}" "${password}" | chpasswd
  chage -E "${expires}" "${username}"
  usermod -U "${username}" >/dev/null 2>&1 || true
  ensure_limits_entry "${username}" "${max_connections}"

  json_ok "create" "${username}" "usuário SSH criado/atualizado com validade até ${expires}"
}

delete_user() {
  local username="$1"
  validate_username "${username}"

  if getent passwd "${username}" >/dev/null 2>&1; then
    pkill -u "${username}" >/dev/null 2>&1 || true
    userdel -r "${username}" >/dev/null 2>&1 || userdel "${username}"
  fi

  remove_limits_entry "${username}"
  json_ok "delete" "${username}" "usuário SSH removido"
}

disable_user() {
  local username="$1"
  validate_username "${username}"
  getent passwd "${username}" >/dev/null 2>&1 || fail "usuário não existe no sistema"

  usermod -L "${username}"
  chage -E 0 "${username}"
  pkill -u "${username}" >/dev/null 2>&1 || true
  json_ok "disable" "${username}" "usuário SSH bloqueado"
}

enable_user() {
  local username="$1"
  local expires="$2"
  validate_username "${username}"
  validate_date "${expires}"
  getent passwd "${username}" >/dev/null 2>&1 || fail "usuário não existe no sistema"

  usermod -U "${username}" >/dev/null 2>&1 || true
  chage -E "${expires}" "${username}"
  json_ok "enable" "${username}" "usuário SSH ativado até ${expires}"
}

change_password() {
  local username="$1"
  local password="$2"
  validate_username "${username}"
  validate_password "${password}"
  getent passwd "${username}" >/dev/null 2>&1 || fail "usuário não existe no sistema"

  printf '%s:%s\n' "${username}" "${password}" | chpasswd
  usermod -U "${username}" >/dev/null 2>&1 || true
  json_ok "password" "${username}" "senha alterada"
}

extend_user() {
  local username="$1"
  local expires="$2"
  validate_username "${username}"
  validate_date "${expires}"
  getent passwd "${username}" >/dev/null 2>&1 || fail "usuário não existe no sistema"

  chage -E "${expires}" "${username}"
  json_ok "extend" "${username}" "validade renovada até ${expires}"
}

usage() {
  cat >&2 <<USAGE
Uso:
  4pluspainel-ssh-helper create USER PASS YYYY-MM-DD MAX_CONNECTIONS
  4pluspainel-ssh-helper delete USER
  4pluspainel-ssh-helper disable USER
  4pluspainel-ssh-helper enable USER YYYY-MM-DD
  4pluspainel-ssh-helper password USER PASS
  4pluspainel-ssh-helper extend USER YYYY-MM-DD
USAGE
}

main() {
  require_root
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}"
  flock -x 9

  local command="${1:-}"
  shift || true

  case "${command}" in
    create)
      [[ $# -eq 4 ]] || { usage; fail "argumentos inválidos para create"; }
      create_user "$1" "$2" "$3" "$4"
      ;;
    delete)
      [[ $# -eq 1 ]] || { usage; fail "argumentos inválidos para delete"; }
      delete_user "$1"
      ;;
    disable)
      [[ $# -eq 1 ]] || { usage; fail "argumentos inválidos para disable"; }
      disable_user "$1"
      ;;
    enable)
      [[ $# -eq 2 ]] || { usage; fail "argumentos inválidos para enable"; }
      enable_user "$1" "$2"
      ;;
    password)
      [[ $# -eq 2 ]] || { usage; fail "argumentos inválidos para password"; }
      change_password "$1" "$2"
      ;;
    extend)
      [[ $# -eq 2 ]] || { usage; fail "argumentos inválidos para extend"; }
      extend_user "$1" "$2"
      ;;
    *)
      usage
      fail "comando inválido"
      ;;
  esac
}

main "$@"
