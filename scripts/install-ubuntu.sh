#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-4pluspainel}"
APP_TITLE="${APP_TITLE:-4G Plus SSH Painel}"
APP_USER="${APP_USER:-www-data}"
APP_DIR="${APP_DIR:-/opt/4pluspainel}"
DATA_DIR="${DATA_DIR:-/var/lib/${APP_NAME}}"
APP_PORT="${APP_PORT:-3000}"
REPO_URL="${REPO_URL:-https://github.com/Alefsousa5/4pluspainel-.git}"
BRANCH="${BRANCH:-arena/01a039e9-4pluspainel}"
DOMAIN="${DOMAIN:-_}"
NODE_MAJOR="${NODE_MAJOR:-20}"
SETUP_NGINX="${SETUP_NGINX:-true}"
INSTALL_SSL="${INSTALL_SSL:-false}"
SSL_EMAIL="${SSL_EMAIL:-}"
ENABLE_SYSTEM_SSH="${ENABLE_SYSTEM_SSH:-true}"
ENABLE_PASSWORD_SSH="${ENABLE_PASSWORD_SSH:-true}"
DEFAULT_SSH_HOST="${DEFAULT_SSH_HOST:-}"
DEFAULT_SSH_PORT="${DEFAULT_SSH_PORT:-22}"
DEFAULT_SERVER_CAPACITY="${DEFAULT_SERVER_CAPACITY:-200}"
STORE_USER_PASSWORDS="${STORE_USER_PASSWORDS:-false}"
SSH_HELPER_PATH="${SSH_HELPER_PATH:-/usr/local/sbin/${APP_NAME}-ssh-helper}"
SSH_USER_SHELL="${SSH_USER_SHELL:-/bin/bash}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
RESOLVED_PANEL_URL=""
RESOLVED_PUBLIC_IP=""

usage() {
  cat <<USAGE
Instalador do 4G Plus SSH Painel para VPS Ubuntu.

Uso:
  sudo bash scripts/install-ubuntu.sh [opções]

Opções:
  --domain DOMINIO        Domínio do painel. Ex.: painel.seudominio.com
  --ssl                   Ativa HTTPS com Certbot. Requer --domain válido e DNS apontado.
  --port PORTA            Porta interna do Node.js. Padrão: 3000
  --ssh-host HOST         Host/IP entregue nas credenciais SSH. Padrão: domínio ou IP público.
  --ssh-port PORTA        Porta SSH entregue aos clientes. Padrão: 22
  --capacity NUM          Capacidade inicial do servidor local. Padrão: 200
  --repo URL              Repositório Git. Padrão: ${REPO_URL}
  --branch BRANCH         Branch Git. Padrão: ${BRANCH}
  --dir DIRETORIO         Diretório de instalação. Padrão: ${APP_DIR}
  --data-dir DIRETORIO    Diretório do banco JSON. Padrão: ${DATA_DIR}
  --no-nginx              Não configura Nginx.
  --no-system-ssh         Não cria usuários Linux reais; apenas aloca no painel.
  --no-password-ssh       Não altera sshd_config para senha/forwarding.
  -h, --help              Mostra esta ajuda.

Variáveis úteis:
  APP_DIR=/srv/4pluspainel APP_PORT=4000 sudo -E bash scripts/install-ubuntu.sh
  SSL_EMAIL=admin@seudominio.com sudo -E bash scripts/install-ubuntu.sh --domain painel.seudominio.com --ssl
  ADMIN_TOKEN=minha-senha-forte sudo -E bash scripts/install-ubuntu.sh
USAGE
}

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

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Execute como root: sudo bash scripts/install-ubuntu.sh"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "Informe o domínio após --domain."
        DOMAIN="$2"
        shift 2
        ;;
      --ssl)
        INSTALL_SSL="true"
        shift
        ;;
      --port)
        [[ $# -ge 2 ]] || die "Informe a porta após --port."
        APP_PORT="$2"
        shift 2
        ;;
      --ssh-host)
        [[ $# -ge 2 ]] || die "Informe o host/IP após --ssh-host."
        DEFAULT_SSH_HOST="$2"
        shift 2
        ;;
      --ssh-port)
        [[ $# -ge 2 ]] || die "Informe a porta após --ssh-port."
        DEFAULT_SSH_PORT="$2"
        shift 2
        ;;
      --capacity)
        [[ $# -ge 2 ]] || die "Informe a capacidade após --capacity."
        DEFAULT_SERVER_CAPACITY="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "Informe a URL após --repo."
        REPO_URL="$2"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 ]] || die "Informe a branch após --branch."
        BRANCH="$2"
        shift 2
        ;;
      --dir)
        [[ $# -ge 2 ]] || die "Informe o diretório após --dir."
        APP_DIR="$2"
        shift 2
        ;;
      --data-dir)
        [[ $# -ge 2 ]] || die "Informe o diretório após --data-dir."
        DATA_DIR="$2"
        shift 2
        ;;
      --no-nginx)
        SETUP_NGINX="false"
        shift
        ;;
      --no-system-ssh)
        ENABLE_SYSTEM_SSH="false"
        shift
        ;;
      --no-password-ssh)
        ENABLE_PASSWORD_SSH="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Opção desconhecida: $1"
        ;;
    esac
  done
}

validate_port() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} precisa ser numérica."
  (( value > 0 && value < 65536 )) || die "${label} precisa estar entre 1 e 65535."
}

validate_inputs() {
  validate_port "${APP_PORT}" "APP_PORT"
  validate_port "${DEFAULT_SSH_PORT}" "DEFAULT_SSH_PORT"

  [[ "${DEFAULT_SERVER_CAPACITY}" =~ ^[0-9]+$ ]] || die "DEFAULT_SERVER_CAPACITY precisa ser numérica."
  (( DEFAULT_SERVER_CAPACITY > 0 && DEFAULT_SERVER_CAPACITY <= 100000 )) || die "DEFAULT_SERVER_CAPACITY inválida."

  if [[ "${INSTALL_SSL}" == "true" && ( -z "${DOMAIN}" || "${DOMAIN}" == "_" ) ]]; then
    die "Para usar --ssl, informe um domínio com --domain painel.seudominio.com."
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    die "Este instalador requer systemd. Use uma VPS Ubuntu padrão."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "Sistema detectado: ${PRETTY_NAME:-desconhecido}. O script foi feito para Ubuntu, mas tentará continuar."
    fi
  fi
}

detect_public_ip() {
  if [[ -n "${RESOLVED_PUBLIC_IP}" ]]; then
    printf '%s' "${RESOLVED_PUBLIC_IP}"
    return
  fi

  RESOLVED_PUBLIC_IP="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"

  if [[ -z "${RESOLVED_PUBLIC_IP}" ]]; then
    RESOLVED_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s' "${RESOLVED_PUBLIC_IP}"
}

resolve_hosts() {
  if [[ -z "${DEFAULT_SSH_HOST}" ]]; then
    if [[ "${DOMAIN}" != "_" && -n "${DOMAIN}" ]]; then
      DEFAULT_SSH_HOST="${DOMAIN}"
    else
      DEFAULT_SSH_HOST="$(detect_public_ip)"
    fi
  fi

  [[ -n "${DEFAULT_SSH_HOST}" ]] || DEFAULT_SSH_HOST="SEU_IP_DA_VPS"

  if [[ "${DOMAIN}" != "_" && -n "${DOMAIN}" ]]; then
    if [[ "${INSTALL_SSL}" == "true" ]]; then
      RESOLVED_PANEL_URL="https://${DOMAIN}"
    else
      RESOLVED_PANEL_URL="http://${DOMAIN}"
    fi
  else
    local ip_address
    ip_address="$(detect_public_ip)"
    if [[ -n "${ip_address}" ]]; then
      RESOLVED_PANEL_URL="http://${ip_address}"
    else
      RESOLVED_PANEL_URL="http://SEU_IP_DA_VPS"
    fi
  fi
}

install_base_packages() {
  log "Atualizando pacotes do Ubuntu..."
  export DEBIAN_FRONTEND=noninteractive

  local packages=(ca-certificates curl gnupg git ufw sudo openssl openssh-server)
  if [[ "${SETUP_NGINX}" == "true" ]]; then
    packages+=(nginx)
  fi

  apt-get update
  apt-get install -y "${packages[@]}"
}

ensure_app_user() {
  if id "${APP_USER}" >/dev/null 2>&1; then
    return
  fi

  log "Criando usuário de serviço ${APP_USER}..."
  if ! getent group "${APP_USER}" >/dev/null 2>&1; then
    groupadd --system "${APP_USER}"
  fi

  useradd --system --gid "${APP_USER}" --home-dir "${DATA_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
}

install_node() {
  local node_ok="false"

  if command -v node >/dev/null 2>&1; then
    local current_major
    current_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
    if [[ "${current_major}" -ge 18 ]]; then
      node_ok="true"
    fi
  fi

  if [[ "${node_ok}" == "true" ]]; then
    log "Node.js já instalado: $(node --version)."
    return
  fi

  log "Instalando Node.js ${NODE_MAJOR}.x LTS..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
  log "Node instalado: $(node --version), npm $(npm --version)."
}

mark_git_directory_safe() {
  git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${APP_DIR}" \
    || git config --global --add safe.directory "${APP_DIR}" 2>/dev/null \
    || true
}

clone_or_update_repo() {
  log "Preparando diretório ${APP_DIR}..."
  mkdir -p "$(dirname "${APP_DIR}")"
  mark_git_directory_safe

  if [[ -d "${APP_DIR}/.git" ]]; then
    log "Repositório existente encontrado. Atualizando branch ${BRANCH}..."
    git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
    git -C "${APP_DIR}" fetch --prune origin "${BRANCH}"
    git -C "${APP_DIR}" checkout -B "${BRANCH}" "origin/${BRANCH}"
    git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
  else
    if [[ -e "${APP_DIR}" && -n "$(find "${APP_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
      die "O diretório ${APP_DIR} existe e não está vazio. Escolha outro com --dir ou limpe o diretório."
    fi

    rm -rf "${APP_DIR}"
    git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${APP_DIR}"
  fi
}

install_app_dependencies() {
  log "Instalando dependências da aplicação..."
  cd "${APP_DIR}"

  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev --no-audit --no-fund
  elif [[ -f package.json ]]; then
    npm install --omit=dev --no-audit --no-fund
  else
    die "package.json não encontrado em ${APP_DIR}."
  fi
}

get_env_value() {
  local key="$1"
  local file="${APP_DIR}/.env"

  if [[ -f "${file}" ]]; then
    grep -E "^${key}=" "${file}" | tail -n 1 | cut -d= -f2- || true
  fi
}

upsert_env() {
  local key="$1"
  local value="$2"
  local file="${APP_DIR}/.env"
  local temp_file

  touch "${file}"
  temp_file="$(mktemp)"

  awk -v key="${key}" -v value="${value}" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (done == 0) print key "=" value }
  ' "${file}" > "${temp_file}"

  cat "${temp_file}" > "${file}"
  rm -f "${temp_file}"
}

ensure_admin_token() {
  local existing_token
  existing_token="$(get_env_value ADMIN_TOKEN)"

  if [[ -n "${ADMIN_TOKEN}" ]]; then
    return
  fi

  if [[ -n "${existing_token}" ]]; then
    ADMIN_TOKEN="${existing_token}"
    return
  fi

  ADMIN_TOKEN="$(openssl rand -hex 24)"
}

write_env_file() {
  log "Gerando arquivo de ambiente..."
  ensure_admin_token

  upsert_env "NODE_ENV" "production"
  upsert_env "HOST" "0.0.0.0"
  upsert_env "PORT" "${APP_PORT}"
  upsert_env "APP_NAME" "${APP_NAME}"
  upsert_env "DATA_DIR" "${DATA_DIR}"
  upsert_env "ADMIN_TOKEN" "${ADMIN_TOKEN}"
  upsert_env "GIT_REPO" "${REPO_URL}"
  upsert_env "GIT_BRANCH" "${BRANCH}"
  upsert_env "ENABLE_SYSTEM_SSH" "${ENABLE_SYSTEM_SSH}"
  upsert_env "STORE_USER_PASSWORDS" "${STORE_USER_PASSWORDS}"
  upsert_env "SSH_HELPER" "${SSH_HELPER_PATH}"
  upsert_env "DEFAULT_SSH_HOST" "${DEFAULT_SSH_HOST}"
  upsert_env "DEFAULT_SSH_PORT" "${DEFAULT_SSH_PORT}"
  upsert_env "DEFAULT_SERVER_CAPACITY" "${DEFAULT_SERVER_CAPACITY}"
}

install_ssh_helper() {
  if [[ "${ENABLE_SYSTEM_SSH}" != "true" ]]; then
    warn "Provisionamento de usuários Linux desativado por --no-system-ssh."
    return
  fi

  log "Instalando helper seguro para criar/bloquear/remover usuários SSH..."
  install -m 0750 -o root -g root "${APP_DIR}/scripts/ssh-helper.sh" "${SSH_HELPER_PATH}"

  local sudoers_file="/etc/sudoers.d/${APP_NAME}-ssh-helper"
  cat > "${sudoers_file}" <<SUDOERS
# Permite que o serviço do ${APP_TITLE} execute apenas o helper de usuários SSH.
${APP_USER} ALL=(root) NOPASSWD: ${SSH_HELPER_PATH} *
SUDOERS

  chmod 0440 "${sudoers_file}"
  visudo -cf "${sudoers_file}" >/dev/null
}

configure_openssh() {
  log "Garantindo OpenSSH Server ativo..."
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || warn "Não foi possível iniciar o serviço SSH automaticamente."

  if [[ "${ENABLE_PASSWORD_SSH}" != "true" ]]; then
    warn "Configuração de senha SSH ignorada por --no-password-ssh."
    return
  fi

  log "Configurando SSH para autenticação por senha e encaminhamento TCP..."
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/90-4pluspainel.conf <<SSHD
# Gerenciado pelo 4G Plus SSH Painel
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
AllowTcpForwarding yes
PermitTunnel yes
X11Forwarding no
PermitRootLogin prohibit-password
SSHD

  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  fi

  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || warn "Não foi possível reiniciar o serviço SSH automaticamente."
}

prepare_permissions() {
  log "Ajustando permissões..."
  mkdir -p "${DATA_DIR}"
  chown -R "${APP_USER}:${APP_USER}" "${DATA_DIR}"
  chmod 0750 "${DATA_DIR}"

  chown -R root:root "${APP_DIR}"
  find "${APP_DIR}" -type d -exec chmod 0755 {} \;
  find "${APP_DIR}" -type f -exec chmod 0644 {} \;
  chmod +x "${APP_DIR}/scripts/"*.sh
  chmod 0600 "${APP_DIR}/.env"
}

write_systemd_service() {
  log "Configurando serviço systemd ${APP_NAME}.service..."

  cat > "/etc/systemd/system/${APP_NAME}.service" <<SERVICE
[Unit]
Description=${APP_TITLE}
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/bin/node ${APP_DIR}/server.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "${APP_NAME}"
  systemctl restart "${APP_NAME}"
}

write_nginx_config() {
  if [[ "${SETUP_NGINX}" != "true" ]]; then
    warn "Configuração do Nginx ignorada por --no-nginx."
    return
  fi

  log "Configurando Nginx..."

  local server_name="${DOMAIN}"
  [[ -n "${server_name}" ]] || server_name="_"

  cat > "/etc/nginx/sites-available/${APP_NAME}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};

    access_log /var/log/nginx/${APP_NAME}.access.log;
    error_log /var/log/nginx/${APP_NAME}.error.log;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 90;
    }
}
NGINX

  ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi

  if ufw status | grep -qi "Status: active"; then
    log "Liberando portas no UFW ativo..."
    ufw allow OpenSSH >/dev/null || true
    ufw allow "${DEFAULT_SSH_PORT}/tcp" >/dev/null || true
    if [[ "${SETUP_NGINX}" == "true" ]]; then
      ufw allow 'Nginx Full' >/dev/null || true
    else
      ufw allow "${APP_PORT}/tcp" >/dev/null || true
    fi
  else
    warn "UFW está inativo. Se ativar depois, libere OpenSSH, ${DEFAULT_SSH_PORT}/tcp e Nginx Full."
  fi
}

setup_ssl() {
  if [[ "${INSTALL_SSL}" != "true" ]]; then
    return
  fi

  if [[ "${SETUP_NGINX}" != "true" ]]; then
    die "SSL automático requer Nginx. Remova --no-nginx."
  fi

  log "Instalando Certbot e solicitando certificado SSL para ${DOMAIN}..."
  apt-get install -y certbot python3-certbot-nginx

  local certbot_args=(--nginx -d "${DOMAIN}" --agree-tos --non-interactive --redirect)

  if [[ -n "${SSL_EMAIL}" ]]; then
    certbot_args+=(--email "${SSL_EMAIL}")
  else
    certbot_args+=(--register-unsafely-without-email)
    warn "SSL_EMAIL não informado. O Certbot será registrado sem e-mail."
  fi

  certbot "${certbot_args[@]}"
}

print_summary() {
  cat <<SUMMARY

============================================================
✅ 4G Plus SSH Painel instalado com sucesso!

URL do painel:      ${RESOLVED_PANEL_URL}
Token admin:        ${ADMIN_TOKEN}
Diretório app:      ${APP_DIR}
Diretório dados:    ${DATA_DIR}
Serviço:            ${APP_NAME}.service
Repositório:        ${REPO_URL}
Branch:             ${BRANCH}
Porta painel Node:  ${APP_PORT}
Host SSH entregue:  ${DEFAULT_SSH_HOST}
Porta SSH entregue: ${DEFAULT_SSH_PORT}
Provisionamento:    ${ENABLE_SYSTEM_SSH}

Guarde o Token admin. Ele será pedido na tela de login do painel.

Comandos úteis:
  sudo systemctl status ${APP_NAME}
  sudo journalctl -u ${APP_NAME} -f
  sudo systemctl restart ${APP_NAME}
  sudo nginx -t
  sudo tail -f /var/log/auth.log

Atualizar depois:
  sudo bash ${APP_DIR}/scripts/update-ubuntu.sh
============================================================
SUMMARY
}

main() {
  parse_args "$@"
  require_root
  validate_inputs
  install_base_packages
  resolve_hosts
  ensure_app_user
  install_node
  clone_or_update_repo
  install_app_dependencies
  write_env_file
  configure_openssh
  install_ssh_helper
  prepare_permissions
  write_systemd_service
  write_nginx_config
  configure_firewall
  setup_ssl
  print_summary
}

main "$@"
