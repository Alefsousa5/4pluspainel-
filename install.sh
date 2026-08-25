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
# Branches tentadas em ordem, caso REPO_BRANCH não seja informada.
REPO_BRANCH="${REPO_BRANCH:-}"
FALLBACK_BRANCHES=("main" "arena/01a038fb-4pluspainel" "master")
DEFAULT_PORT=8080
PUBLIC_HOST=""

RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

info()  { echo "${BLUE}[*]${NC} $*"; }
ok()    { echo "${GREEN}[✓]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }

# die() marca que a mensagem já foi exibida, para o trap não duplicar o erro.
die() {
  DIED=1
  echo "${RED}[x]${NC} $*" >&2
  exit 1
}

DIED=0
on_error() {
  local line="$1"
  [[ "$DIED" == "1" ]] && exit 1   # erro já reportado por die()
  echo "${RED}[x]${NC} Falha inesperada na linha ${line}." >&2
  echo "    Rode novamente; se persistir, envie a saída acima." >&2
  exit 1
}
trap 'on_error $LINENO' ERR

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
# Gera uma senha aleatória.
# Obs.: usar `tr ... | head -c` quebra com `set -e` porque o head fecha o pipe
# e o tr morre com SIGPIPE — por isso o corte é feito com `cut`.
gen_password() {
  head -c 400 /dev/urandom | tr -dc 'a-z0-9' | cut -c1-12
}

ask_config() {
  if [[ -n "${PANEL_UNATTENDED:-}" ]]; then
    PORT="${PANEL_PORT:-$DEFAULT_PORT}"
    ADMIN_USER="${PANEL_ADMIN:-admin}"
    ADMIN_PASS="${PANEL_ADMIN_PASS:-$(gen_password)}"
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
    ADMIN_PASS="$(gen_password)"
    info "Senha gerada automaticamente."
  elif (( ${#ADMIN_PASS} < 4 )); then
    die "A senha precisa ter ao menos 4 caracteres."
  fi
}

# --------------------------------------------------------------------------- #
# Instalação
# --------------------------------------------------------------------------- #
# Endereço que os clientes usarão para conectar no SSH (IP público ou domínio).
# Fica gravado no serviço para o painel exibir os dados corretos ao revendedor.
resolve_public_host() {
  PUBLIC_HOST="${PANEL_PUBLIC_HOST:-$(public_ip)}"
  if [[ "$PUBLIC_HOST" == "SEU_IP" ]]; then
    PUBLIC_HOST=""
    warn "Não foi possível descobrir o IP público; o painel tentará detectá-lo sozinho."
  else
    info "Endereço para os clientes: ${PUBLIC_HOST}"
  fi
}

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

# Baixa o painel testando as branches candidatas até achar uma que
# realmente contenha o código (evita instalar um repositório só com README).
clone_repo() {
  local candidates=()
  if [[ -n "$REPO_BRANCH" ]]; then
    candidates=("$REPO_BRANCH")
  else
    candidates=("${FALLBACK_BRANCHES[@]}")
  fi

  local tmp br
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  for br in "${candidates[@]}"; do
    git ls-remote --exit-code --heads "$REPO_URL" "$br" >/dev/null 2>&1 || continue
    info "Baixando o painel (branch ${br})..."
    rm -rf "${tmp}/repo"
    git clone --depth 1 -b "$br" "$REPO_URL" "${tmp}/repo" -q 2>/dev/null || continue

    if [[ -f "${tmp}/repo/app/main.py" ]]; then
      # Preserva o banco de dados de uma instalação anterior.
      if [[ -d "$DATA_DIR" ]]; then
        info "Preservando dados existentes (contas e revendas)..."
        mv "$DATA_DIR" "${tmp}/data_backup"
      fi
      rm -rf "$INSTALL_DIR"
      mkdir -p "$(dirname "$INSTALL_DIR")"
      mv "${tmp}/repo" "$INSTALL_DIR"
      if [[ -d "${tmp}/data_backup" ]]; then
        rm -rf "$DATA_DIR"
        mv "${tmp}/data_backup" "$DATA_DIR"
        ok "Dados anteriores restaurados."
      fi
      ok "Código obtido da branch '${br}'."
      return 0
    fi
    warn "A branch '${br}' não contém o painel; tentando a próxima..."
  done

  die "Não encontrei os arquivos do painel no repositório.
      Rode novamente informando a branch correta, por exemplo:
      REPO_BRANCH=arena/01a038fb-4pluspainel bash install.sh"
}

fetch_code() {
  local src; src="$(dirname "$(readlink -f "$0")")"

  if [[ -f "${src}/app/main.py" ]]; then
    # rodando de dentro do repositório já clonado
    info "Copiando arquivos de ${src}..."
    mkdir -p "$INSTALL_DIR"
    cp -r "${src}/app" "${src}/requirements.txt" "$INSTALL_DIR"/
    [[ -f "${src}/painel" ]] && cp "${src}/painel" "$INSTALL_DIR"/
  elif [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Atualizando instalação existente..."
    local br; br="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    if git -C "$INSTALL_DIR" fetch --depth 1 origin "$br" -q 2>/dev/null; then
      git -C "$INSTALL_DIR" reset --hard "origin/${br}" -q
    else
      warn "Não foi possível atualizar; refazendo o download."
      clone_repo
    fi
  else
    clone_repo
  fi

  [[ -f "${INSTALL_DIR}/app/main.py" ]] || die "Arquivos do painel não encontrados em ${INSTALL_DIR}."
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
  info "Configurando administrador..."
  PANEL_DATA_DIR="$DATA_DIR" "${INSTALL_DIR}/.venv/bin/python" - \
      "$INSTALL_DIR" "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import sys
install_dir, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, install_dir)
from app.database import init_db, execute, query_one, now
from app.security import hash_password

init_db(username, password)
row = query_one("SELECT id FROM admins WHERE username = ?", (username,))
if row:
    # Já existia (reinstalação/atualização): garante que está ativo e como
    # admin, mas só troca a senha se uma nova foi realmente informada.
    if password:
        execute("UPDATE admins SET password_hash = ?, role = 'admin', active = 1 WHERE id = ?",
                (hash_password(password), row["id"]))
    else:
        execute("UPDATE admins SET role = 'admin', active = 1 WHERE id = ?", (row["id"],))
    print("existente")
else:
    execute("INSERT INTO admins (username, password_hash, role, user_limit, active, created_at)"
            " VALUES (?, ?, 'admin', 0, 1, ?)", (username, hash_password(password), now()))
    print("novo")
PY
  ok "Administrador '${ADMIN_USER}' configurado."
}

# As contas criadas pelo painel autenticam por SENHA e usam shell /bin/false.
# Em quase toda VPS de nuvem o SSH vem com PasswordAuthentication no, o que
# tornaria essas contas inutilizáveis. Aqui isso é corrigido de forma segura:
# a regra é aplicada em um arquivo próprio dentro de sshd_config.d, sem
# reescrever a configuração original do servidor.
configure_ssh() {
  local sshd=/etc/ssh/sshd_config
  local dropin_dir=/etc/ssh/sshd_config.d
  local dropin="${dropin_dir}/99-4pluspainel.conf"

  [[ -f "$sshd" ]] || { warn "sshd_config não encontrado; pulando ajuste do SSH."; return; }

  # O binário do sshd não costuma estar no PATH do root em todos os sistemas.
  local SSHD_BIN=""
  local cand
  for cand in /usr/sbin/sshd /sbin/sshd "$(command -v sshd 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { SSHD_BIN="$cand"; break; }
  done

  # /bin/false precisa constar em /etc/shells para o login de túnel funcionar
  # com alguns módulos PAM (pam_shells).
  grep -qx '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
  grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

  # Backup único da configuração original.
  [[ -f "${sshd}.4plus.bak" ]] || cp "$sshd" "${sshd}.4plus.bak"

  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd" && [[ -d "$dropin_dir" ]]; then
    # Caminho moderno (Debian 11+/Ubuntu 22.04+): usa drop-in.
    cat > "$dropin" <<'EOF'
# 4Plus Painel — as contas do painel autenticam por senha.
# Remova este arquivo se desativar o painel.
PasswordAuthentication yes
EOF
    chmod 644 "$dropin"
    ok "SSH configurado via ${dropin}"
  else
    # Sem suporte a Include: edita o arquivo principal com cuidado.
    if grep -qiE '^\s*PasswordAuthentication\s+' "$sshd"; then
      sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/I' "$sshd"
    else
      printf '\n# 4Plus Painel\nPasswordAuthentication yes\n' >> "$sshd"
    fi
    ok "SSH configurado em ${sshd} (backup em ${sshd}.4plus.bak)"
  fi

  # Alguns provedores forçam a negativa em drop-ins que vêm depois na ordem
  # alfabética (ex.: 60-cloudimg-settings.conf). Neutraliza esses casos.
  local f
  for f in "${dropin_dir}"/*.conf; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$dropin" ]] && continue
    if grep -qiE '^\s*PasswordAuthentication\s+no' "$f"; then
      sed -i -E 's/^(\s*PasswordAuthentication\s+no)/# \1  # desativado pelo 4Plus Painel/I' "$f"
      warn "Ajustado ${f} (PasswordAuthentication estava desativado)."
    fi
  done

  # Valida a configuração ANTES de reiniciar — nunca deixa o SSH quebrado.
  if [[ -n "$SSHD_BIN" ]] && ! "$SSHD_BIN" -t 2>/tmp/4plus_sshd_test.err; then
    warn "A configuração do SSH ficou inválida; restaurando o backup."
    cp "${sshd}.4plus.bak" "$sshd"
    rm -f "$dropin"
    cat /tmp/4plus_sshd_test.err >&2 || true
    warn "SSH mantido como estava. Ative PasswordAuthentication manualmente."
    return
  fi

  # Recarrega sem derrubar as sessões existentes.
  local svc
  for svc in ssh sshd; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
      break
    fi
  done

  # Obs.: `cmd | grep -q` fecha o pipe cedo e, com `pipefail`, retorna 141
  # (SIGPIPE). Por isso a saída é capturada antes de ser inspecionada.
  local effective=""
  [[ -n "$SSHD_BIN" ]] && effective="$("$SSHD_BIN" -T 2>/dev/null || true)"
  if [[ "$effective" == *"passwordauthentication yes"* ]]; then
    ok "Autenticação por senha ativa — as contas do painel vão conectar."
  else
    warn "Não foi possível confirmar PasswordAuthentication."
    warn "Verifique com: ${SSHD_BIN:-sshd} -T | grep -i passwordauth"
  fi
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
Environment=PANEL_PUBLIC_HOST=${PUBLIC_HOST}
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
  local ip=""
  ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${ip:-SEU_IP}"
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
  resolve_public_host
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
