#!/usr/bin/env bash
#
# 4Plus Painel — instalador para VPS (Debian/Ubuntu)
#
#   bash <(curl -sSL https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/main/install.sh)
#
# Instala dependências, cria o serviço systemd e sobe o painel.
#
set -Eeuo pipefail

APP_NAME="4Plus Painel"
APP_USER="4pluspainel"
INSTALL_DIR="/opt/4pluspainel"
DATA_DIR="${INSTALL_DIR}/data"
SERVICE="4pluspainel"
REPO_URL="${REPO_URL:-https://github.com/Alefsousa5/4pluspainel-.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEFAULT_PORT=8080

RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

info()  { echo "${BLUE}[*]${NC} $*"; }
ok()    { echo "${GREEN}[✓]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
die()   { echo "${RED}[x]${NC} $*" >&2; exit 1; }

trap 'die "Falha na linha $LINENO. Instalação abortada."' ERR

banner() {
  clear 2>/dev/null || true
  echo "${BLUE}${BOLD}"
  echo "   ╔══════════════════════════════════════════╗"
  echo "   ║          4 P L U S   P A I N E L         ║"
  echo "   ║      Gerenciador de contas SSH v1.0      ║"
  echo "   ╚══════════════════════════════════════════╝"
  echo "${NC}"
}

# --------------------------------------------------------------------------- #
# Verificações
# --------------------------------------------------------------------------- #
check_root() {
  [[ $EUID -eq 0 ]] || die "Execute como root:  sudo bash install.sh"
}

check_os() {
  [[ -f /etc/os-release ]] || die "Sistema não suportado (sem /etc/os-release)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "Sistema detectado: ${PRETTY_NAME}" ;;
    *) warn "Distribuição '${PRETTY_NAME:-desconhecida}' não é oficialmente suportada (esperado Debian/Ubuntu). Continuando..." ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd é necessário para instalar o serviço."
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q LISTEN
  else
    return 1
  fi
}

# --------------------------------------------------------------------------- #
# Entrada do usuário
# --------------------------------------------------------------------------- #
ask_config() {
  if [[ -n "${PANEL_UNATTENDED:-}" ]]; then
    PORT="${PANEL_PORT:-$DEFAULT_PORT}"
    ADMIN_USER="${PANEL_ADMIN:-admin}"
    ADMIN_PASS="${PANEL_ADMIN_PASS:-$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)}"
    info "Instalação silenciosa: porta ${PORT}, admin ${ADMIN_USER}"
    return
  fi

  read -rp "$(echo "${BOLD}Porta do painel${NC} [${DEFAULT_PORT}]: ")" PORT
  PORT="${PORT:-$DEFAULT_PORT}"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "Porta inválida: $PORT"
  if port_in_use "$PORT"; then
    warn "A porta ${PORT} já está em uso — o serviço pode não subir."
    read -rp "Continuar mesmo assim? [s/N]: " go
    [[ "${go,,}" == "s" ]] || die "Instalação cancelada."
  fi

  read -rp "$(echo "${BOLD}Usuário administrador${NC} [admin]: ")" ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"

  read -rsp "$(echo "${BOLD}Senha do administrador${NC} (enter = gerar): ")" ADMIN_PASS; echo
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
    info "Senha gerada automaticamente."
  elif (( ${#ADMIN_PASS} < 4 )); then
    die "A senha precisa ter ao menos 4 caracteres."
  fi
}

# --------------------------------------------------------------------------- #
# Instalação
# --------------------------------------------------------------------------- #
install_packages() {
  info "Atualizando índices de pacotes..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "Falha ao atualizar índices; seguindo com o cache local."

  info "Instalando dependências (python3, git, openssh-server)..."
  apt-get install -y -qq \
    python3 python3-venv python3-pip \
    git curl ca-certificates \
    openssh-server iproute2 procps >/dev/null
  ok "Dependências instaladas."
}

fetch_code() {
  if [[ -f "$(dirname "$(readlink -f "$0")")/app/main.py" ]]; then
    # rodando de dentro do repositório já clonado
    local src; src="$(dirname "$(readlink -f "$0")")"
    info "Copiando arquivos de ${src}..."
    mkdir -p "$INSTALL_DIR"
    cp -r "${src}/app" "${src}/requirements.txt" "$INSTALL_DIR"/
    [[ -f "${src}/painel" ]] && cp "${src}/painel" "$INSTALL_DIR"/
  elif [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Atualizando instalação existente..."
    git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH" -q
    git -C "$INSTALL_DIR" reset --hard "origin/${REPO_BRANCH}" -q
  else
    info "Baixando o painel de ${REPO_URL}..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" -q \
      || die "Não foi possível clonar o repositório."
  fi
  mkdir -p "$DATA_DIR"
  ok "Arquivos em ${INSTALL_DIR}"
}

setup_venv() {
  info "Criando ambiente virtual Python..."
  python3 -m venv "${INSTALL_DIR}/.venv"
  "${INSTALL_DIR}/.venv/bin/pip" install --quiet --upgrade pip
  "${INSTALL_DIR}/.venv/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt" \
    || die "Falha ao instalar as dependências Python."
  ok "Ambiente Python pronto."
}

create_admin() {
  info "Criando administrador inicial..."
  PANEL_DATA_DIR="$DATA_DIR" "${INSTALL_DIR}/.venv/bin/python" - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import sys, os
sys.path.insert(0, "/opt/4pluspainel")
from app.database import init_db, execute, query_one, now
from app.security import hash_password

username, password = sys.argv[1], sys.argv[2]
init_db(username, password)
row = query_one("SELECT id FROM admins WHERE username = ?", (username,))
if row:
    execute("UPDATE admins SET password_hash = ?, role = 'admin', active = 1 WHERE id = ?",
            (hash_password(password), row["id"]))
else:
    execute("INSERT INTO admins (username, password_hash, role, user_limit, active, created_at)"
            " VALUES (?, ?, 'admin', 0, 1, ?)", (username, hash_password(password), now()))
PY
  ok "Administrador '${ADMIN_USER}' configurado."
}

configure_ssh() {
  local sshd=/etc/ssh/sshd_config
  [[ -f "$sshd" ]] || { warn "sshd_config não encontrado; pulando ajuste do SSH."; return; }

  # Contas de túnel usam /bin/false: o SSH precisa aceitar senha.
  if grep -qiE '^\s*PasswordAuthentication\s+no' "$sshd"; then
    warn "PasswordAuthentication está desativado no SSH."
    warn "As contas criadas pelo painel usam senha — ajuste ${sshd} se precisar."
  fi

  # Garante que /bin/false seja um shell válido para login por túnel
  if ! grep -qx '/bin/false' /etc/shells 2>/dev/null; then
    echo '/bin/false' >> /etc/shells
  fi
  ok "SSH verificado."
}

create_service() {
  info "Criando serviço systemd..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=${APP_NAME} — gerenciador de contas SSH
After=network.target sshd.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=PANEL_DATA_DIR=${DATA_DIR}
Environment=PANEL_PORT=${PORT}
Environment=PYTHONUNBUFFERED=1
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" -q
  systemctl restart "$SERVICE"
  sleep 3

  if systemctl is-active --quiet "$SERVICE"; then
    ok "Serviço ativo."
  else
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    die "O serviço não iniciou. Veja o log acima."
  fi
}

install_cli() {
  if [[ -f "${INSTALL_DIR}/painel" ]]; then
    install -m 755 "${INSTALL_DIR}/painel" /usr/local/bin/painel
    ok "Comando 'painel' instalado."
  fi
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && ok "Porta ${PORT} liberada no UFW."
  fi
}

public_ip() {
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "SEU_IP"
}

finish() {
  local ip; ip="$(public_ip)"
  echo
  echo "${GREEN}${BOLD}   ╔══════════════════════════════════════════╗${NC}"
  echo "${GREEN}${BOLD}   ║        INSTALAÇÃO CONCLUÍDA! 🎉          ║${NC}"
  echo "${GREEN}${BOLD}   ╚══════════════════════════════════════════╝${NC}"
  echo
  echo "   ${BOLD}Acesse:${NC}  http://${ip}:${PORT}"
  echo "   ${BOLD}Usuário:${NC} ${ADMIN_USER}"
  echo "   ${BOLD}Senha:${NC}   ${ADMIN_PASS}"
  echo
  echo "   ${YELLOW}Anote a senha agora — ela não será exibida novamente.${NC}"
  echo
  echo "   Comandos úteis:"
  echo "     painel status      — situação do serviço"
  echo "     painel restart     — reiniciar"
  echo "     painel logs        — acompanhar o log"
  echo "     painel senha       — trocar a senha do admin"
  echo "     painel desinstalar — remover o painel"
  echo
}

main() {
  banner
  check_root
  check_os
  ask_config
  install_packages
  fetch_code
  setup_venv
  create_admin
  configure_ssh
  create_service
  install_cli
  open_firewall
  finish
}

main "$@"
