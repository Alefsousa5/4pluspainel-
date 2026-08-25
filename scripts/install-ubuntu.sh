#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-4pluspainel}"
APP_TITLE="${APP_TITLE:-4G Plus Painel}"
APP_USER="${APP_USER:-www-data}"
APP_DIR="${APP_DIR:-/opt/4pluspainel}"
APP_PORT="${APP_PORT:-3000}"
REPO_URL="${REPO_URL:-https://github.com/Alefsousa5/4pluspainel-.git}"
BRANCH="${BRANCH:-arena/01a039e9-4pluspainel}"
DOMAIN="${DOMAIN:-_}"
NODE_MAJOR="${NODE_MAJOR:-20}"
SETUP_NGINX="${SETUP_NGINX:-true}"
INSTALL_SSL="${INSTALL_SSL:-false}"
SSL_EMAIL="${SSL_EMAIL:-}"

usage() {
  cat <<USAGE
Instalador do 4G Plus Painel para VPS Ubuntu.

Uso:
  sudo bash scripts/install-ubuntu.sh [opções]

Opções:
  --domain DOMINIO    Domínio do painel. Ex.: painel.seudominio.com
  --ssl               Ativa HTTPS com Certbot. Requer --domain válido e DNS apontado.
  --port PORTA        Porta interna do Node.js. Padrão: 3000
  --repo URL          Repositório Git. Padrão: ${REPO_URL}
  --branch BRANCH     Branch Git. Padrão: ${BRANCH}
  --dir DIRETORIO     Diretório de instalação. Padrão: ${APP_DIR}
  --no-nginx          Não configura Nginx.
  -h, --help          Mostra esta ajuda.

Variáveis úteis:
  APP_DIR=/srv/4pluspainel APP_PORT=4000 sudo -E bash scripts/install-ubuntu.sh
  SSL_EMAIL=admin@seudominio.com sudo -E bash scripts/install-ubuntu.sh --domain painel.seudominio.com --ssl
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
      --no-nginx)
        SETUP_NGINX="false"
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

validate_inputs() {
  [[ "${APP_PORT}" =~ ^[0-9]+$ ]] || die "APP_PORT precisa ser numérico."
  (( APP_PORT > 0 && APP_PORT < 65536 )) || die "APP_PORT precisa estar entre 1 e 65535."

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

install_base_packages() {
  log "Atualizando pacotes do Ubuntu..."
  export DEBIAN_FRONTEND=noninteractive

  local packages=(ca-certificates curl gnupg git ufw)
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

  useradd --system --gid "${APP_USER}" --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
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

upsert_env() {
  local key="$1"
  local value="$2"
  local file="${APP_DIR}/.env"

  touch "${file}"

  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

write_env_file() {
  log "Gerando arquivo de ambiente..."
  upsert_env "NODE_ENV" "production"
  upsert_env "HOST" "0.0.0.0"
  upsert_env "PORT" "${APP_PORT}"
  upsert_env "APP_NAME" "${APP_TITLE}"
  upsert_env "GIT_REPO" "${REPO_URL}"
  upsert_env "GIT_BRANCH" "${BRANCH}"
}

write_systemd_service() {
  log "Configurando serviço systemd ${APP_NAME}.service..."

  cat > "/etc/systemd/system/${APP_NAME}.service" <<SERVICE
[Unit]
Description=${APP_TITLE}
After=network-online.target
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
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
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
    if [[ "${SETUP_NGINX}" == "true" ]]; then
      ufw allow 'Nginx Full' >/dev/null || true
    else
      ufw allow "${APP_PORT}/tcp" >/dev/null || true
    fi
  else
    warn "UFW está inativo. Se ativar depois, libere OpenSSH e Nginx Full."
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
  local ip_address=""
  ip_address="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"

  if [[ -z "${ip_address}" ]]; then
    ip_address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  local url
  if [[ "${DOMAIN}" != "_" && -n "${DOMAIN}" ]]; then
    if [[ "${INSTALL_SSL}" == "true" ]]; then
      url="https://${DOMAIN}"
    else
      url="http://${DOMAIN}"
    fi
  elif [[ -n "${ip_address}" ]]; then
    url="http://${ip_address}"
  else
    url="http://SEU_IP_DA_VPS"
  fi

  cat <<SUMMARY

============================================================
✅ 4G Plus Painel instalado com sucesso!

URL do painel: ${url}
Diretório:     ${APP_DIR}
Serviço:       ${APP_NAME}.service
Repositório:   ${REPO_URL}
Branch:        ${BRANCH}
Porta interna: ${APP_PORT}

Comandos úteis:
  sudo systemctl status ${APP_NAME}
  sudo journalctl -u ${APP_NAME} -f
  sudo systemctl restart ${APP_NAME}
  sudo nginx -t

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
  ensure_app_user
  install_node
  clone_or_update_repo
  install_app_dependencies
  write_env_file
  write_systemd_service
  write_nginx_config
  configure_firewall
  setup_ssl
  print_summary
}

main "$@"
