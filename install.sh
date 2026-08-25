#!/usr/bin/env bash
#
#  ┌──────────────────────────────────────────────────────────────────────┐
#  │  4PLUS PAINEL — instalador para VPS Debian / Ubuntu                  │
#  │                                                                      │
#  │  Repositório : https://github.com/Alefsousa5/4pluspainel-            │
#  │  Clone (git) : https://github.com/Alefsousa5/4pluspainel-.git        │
#  │                                                                      │
#  │  Uso:  sudo bash install.sh                                          │
#  └──────────────────────────────────────────────────────────────────────┘
#
#  O QUE ESTE SCRIPT FAZ
#    1. verifica o sistema, o Python e as dependências
#    2. baixa o painel do GitHub (ou usa os arquivos locais)
#    3. cria o ambiente virtual Python e instala as bibliotecas
#    4. cria o administrador inicial
#    5. ativa a autenticação por senha no SSH (as contas do painel usam senha)
#    6. registra o serviço systemd e sobe o painel
#    7. instala os comandos 'painel' e 'painel-diagnostico'
#
#  VARIÁVEIS ACEITAS
#    GITHUB_REPO=usuario/repo     usar outro repositório (ex.: seu fork)
#    GITHUB_TOKEN=ghp_xxx         token, apenas se o repositório for privado
#    REPO_BRANCH=nome             branch específica (por padrão procura sozinho)
#    PANEL_PORT=8080              porta do painel
#    PANEL_ADMIN=admin            usuário administrador
#    PANEL_ADMIN_PASS=senha       senha do administrador
#    PANEL_PUBLIC_HOST=ip/domínio endereço que os clientes usam no SSH
#    PANEL_UNATTENDED=1           instala sem perguntar nada
#
#  Se algo falhar:  sudo bash diagnostico.sh
#
set -Eeuo pipefail

# =========================================================================== #
#  1. CONFIGURAÇÃO
# =========================================================================== #

APP_NAME="4Plus Painel"
APP_VERSION="1.0"
INSTALL_DIR="/opt/4pluspainel"
DATA_DIR="${INSTALL_DIR}/data"
SERVICE="4pluspainel"
DEFAULT_PORT=8080
LOGFILE="/var/log/4pluspainel-install.log"

# --------------------------------------------------------------------------- #
#  GITHUB — de onde o painel é baixado e atualizado
# --------------------------------------------------------------------------- #
#  >>> Para usar o SEU repositório, altere a linha abaixo (usuário/repo)  <<<
GITHUB_REPO="${GITHUB_REPO:-Alefsousa5/4pluspainel-}"

GITHUB_HOST="${GITHUB_HOST:-github.com}"          # mude só p/ GitHub Enterprise
GITHUB_TOKEN="${GITHUB_TOKEN:-}"                  # só p/ repositório privado

# URL final:  https://github.com/Alefsousa5/4pluspainel-.git
if [[ -n "${REPO_URL:-}" ]]; then
  :                                               # URL manual tem prioridade
elif [[ -n "$GITHUB_TOKEN" ]]; then
  REPO_URL="https://${GITHUB_TOKEN}@${GITHUB_HOST}/${GITHUB_REPO}.git"
else
  REPO_URL="https://${GITHUB_HOST}/${GITHUB_REPO}.git"
fi

# Branches tentadas em ordem quando REPO_BRANCH não é informada.
REPO_BRANCH="${REPO_BRANCH:-}"
FALLBACK_BRANCHES=("main" "arena/01a038fb-4pluspainel" "master")

# Preenchidas durante a execução.
PORT=""; ADMIN_USER=""; ADMIN_PASS=""; PUBLIC_HOST=""; TTY_IN=""

# =========================================================================== #
#  2. SAÍDA E TRATAMENTO DE ERRO
# =========================================================================== #

RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[1;36m'; BOLD=$'\e[1m';    NC=$'\e[0m'

info() { echo "${BLUE}[*]${NC} $*"; }
ok()   { echo "${GREEN}[✓]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }

DIED=0
die() { DIED=1; echo "${RED}[x]${NC} $*" >&2; exit 1; }

on_error() {
  local line="$1" cmd="${BASH_COMMAND:-?}"
  if [[ "$DIED" == "1" ]]; then
    [[ -f "$LOGFILE" ]] && echo "    Log: ${LOGFILE}" >&2
    exit 1
  fi
  echo "${RED}[x]${NC} Falha inesperada na linha ${line}." >&2
  echo "    Comando: ${cmd}" >&2
  [[ -f "$LOGFILE" ]] && echo "    Log: ${LOGFILE}" >&2
  echo >&2
  echo "    Para descobrir a causa:  ${BOLD}sudo bash diagnostico.sh${NC}" >&2
  exit 1
}
trap 'on_error $LINENO' ERR

# Registra tudo em arquivo, com um cabeçalho descrevendo a VPS.
start_logging() {
  : > "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/4pluspainel-install.log"
  {
    echo "===== ${APP_NAME} — instalação em $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "repo    : ${GITHUB_HOST}/${GITHUB_REPO}"
    echo "sistema : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")"
    echo "kernel  : $(uname -srm)"
    echo "python  : $(python3 -V 2>&1)"
    echo "disco   : $(df -h / 2>/dev/null | awk 'NR==2{print $4" livre"}')"
    echo "memoria : $(free -m 2>/dev/null | awk '/Mem:/{print $7"MB disponivel"}')"
    echo "=================================================================="
  } >> "$LOGFILE" 2>&1
  exec > >(tee -a "$LOGFILE") 2>&1
}

banner() {
  clear 2>/dev/null || true
  echo "${BLUE}${BOLD}"
  echo "   ╔══════════════════════════════════════════╗"
  echo "   ║          4 P L U S   P A I N E L         ║"
  echo "   ║      Gerenciador de contas SSH v${APP_VERSION}      ║"
  echo "   ╚══════════════════════════════════════════╝"
  echo "${NC}"
  echo "   Repositório: ${BOLD}https://${GITHUB_HOST}/${GITHUB_REPO}${NC}"
  echo
}

# =========================================================================== #
#  3. PERGUNTAS AO USUÁRIO
# =========================================================================== #
#  Com 'curl | bash' o stdin não é um terminal e 'read' retorna EOF na hora.
#  Sob 'set -e' isso derrubaria o script, então as perguntas vão para
#  /dev/tty e, se nem isso existir, os valores padrão são usados.

detect_tty() {
  if [[ -t 0 ]]; then
    TTY_IN="/dev/stdin"
  elif [[ -r /dev/tty ]] && : 2>/dev/null >/dev/tty; then
    TTY_IN="/dev/tty"
  else
    TTY_IN=""
  fi
}

ask() {  # ask <variável> <pergunta> <padrão>
  local __v="$1" __p="$2" __d="$3" __r=""
  if [[ -z "$TTY_IN" ]]; then printf -v "$__v" '%s' "$__d"; return 0; fi
  read -rp "$__p" __r <"$TTY_IN" || __r=""
  printf -v "$__v" '%s' "${__r:-$__d}"
}

ask_secret() {  # ask_secret <variável> <pergunta>   (não ecoa)
  local __v="$1" __p="$2" __r=""
  if [[ -z "$TTY_IN" ]]; then printf -v "$__v" '%s' ""; return 0; fi
  read -rsp "$__p" __r <"$TTY_IN" || __r=""
  echo
  printf -v "$__v" '%s' "$__r"
}

# 'tr | head -c' morre com SIGPIPE e derruba o script sob 'set -e'.
gen_password() { head -c 400 /dev/urandom | tr -dc 'a-z0-9' | cut -c1-12; }

port_in_use() {
  local porta="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | grep -q ":${porta} "
}

ask_config() {
  detect_tty

  if [[ -n "${PANEL_UNATTENDED:-}" || -z "$TTY_IN" ]]; then
    PORT="${PANEL_PORT:-$DEFAULT_PORT}"
    ADMIN_USER="${PANEL_ADMIN:-admin}"
    ADMIN_PASS="${PANEL_ADMIN_PASS:-$(gen_password)}"
    if [[ -z "$TTY_IN" && -z "${PANEL_UNATTENDED:-}" ]]; then
      info "Sem terminal interativo — usando os valores padrão."
      info "Para escolher porta e senha: baixe o arquivo e rode 'sudo bash install.sh'."
    else
      info "Instalação silenciosa: porta ${PORT}, admin ${ADMIN_USER}"
    fi
    return
  fi

  ask PORT "$(printf '%sPorta do painel%s [%s]: ' "$BOLD" "$NC" "$DEFAULT_PORT")" "$DEFAULT_PORT"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "Porta inválida: ${PORT}"
  fi
  if port_in_use "$PORT"; then
    warn "A porta ${PORT} já está em uso — o serviço pode não subir."
    ask go "Continuar mesmo assim? [s/N]: " "n"
    [[ "${go,,}" == "s" ]] || die "Instalação cancelada."
  fi

  ask ADMIN_USER "$(printf '%sUsuário administrador%s [admin]: ' "$BOLD" "$NC")" "admin"

  ask_secret ADMIN_PASS "$(printf '%sSenha do administrador%s (enter = gerar): ' "$BOLD" "$NC")"
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(gen_password)"
    info "Senha gerada automaticamente."
  elif (( ${#ADMIN_PASS} < 4 )); then
    die "A senha precisa ter ao menos 4 caracteres."
  fi
}

# =========================================================================== #
#  4. VERIFICAÇÕES DO SISTEMA
# =========================================================================== #

check_root() {
  [[ $EUID -eq 0 ]] || die "Execute como root:  sudo bash install.sh"
}

check_os() {
  [[ -f /etc/os-release ]] || { warn "Distribuição desconhecida; continuando."; return; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "Sistema: ${PRETTY_NAME}" ;;
    *) warn "'${PRETTY_NAME:-?}' não é oficialmente suportado (esperado Debian/Ubuntu)." ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd é necessário para instalar o serviço."
}

# O painel usa recursos disponíveis a partir do Python 3.8.
check_python_version() {
  local ver maior menor
  ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
  [[ -n "$ver" ]] || die "Python 3 não encontrado. Instale com: apt install -y python3"
  maior="${ver%%.*}"; menor="${ver##*.}"
  if (( maior < 3 || (maior == 3 && menor < 8) )); then
    die "Python ${ver} é antigo demais — o painel precisa de 3.8 ou superior."
  fi
  ok "Python ${ver} detectado."
}

install_packages() {
  info "Atualizando índices de pacotes..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "Falha ao atualizar índices; usando o cache local."

  info "Instalando dependências (python3, git, openssh-server)..."
  apt-get install -y -qq \
    python3 python3-venv python3-pip \
    git curl ca-certificates \
    openssh-server iproute2 procps >/dev/null
  ok "Dependências instaladas."
}

# Endereço que os clientes usam para conectar no SSH.
public_ip() {
  local ip=""
  ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${ip:-SEU_IP}"
}

resolve_public_host() {
  PUBLIC_HOST="${PANEL_PUBLIC_HOST:-$(public_ip)}"
  if [[ "$PUBLIC_HOST" == "SEU_IP" ]]; then
    PUBLIC_HOST=""
    warn "Não foi possível descobrir o IP público; o painel tentará sozinho."
  else
    info "Endereço para os clientes: ${PUBLIC_HOST}"
  fi
}

# =========================================================================== #
#  5. DOWNLOAD DO CÓDIGO (GITHUB)
# =========================================================================== #

# Valida o acesso antes de baixar, separando problema de rede/credencial
# de problema do próprio painel.
check_github() {
  info "Verificando acesso ao GitHub (${GITHUB_REPO})..."
  command -v git >/dev/null 2>&1 || die "git não instalado. Use: apt install -y git"

  # Sob 'set -e' uma atribuição que falha aborta a função antes do 'rc=$?';
  # por isso o resultado é capturado com '&& rc=0 || rc=$?'.
  local saida rc
  saida="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REPO_URL" 2>&1)" && rc=0 || rc=$?

  if (( rc == 0 )); then
    local n; n="$(echo "$saida" | grep -c 'refs/heads/' || true)"
    ok "GitHub acessível — ${n} branch(es) encontrada(s)."
    return 0
  fi

  echo "$saida" | sed 's/^/      /' >&2
  case "$saida" in
    *"Authentication failed"*|*"could not read Username"*|*"Invalid username"*)
      die "Falha de autenticação no GitHub.
      Repositório privado? Informe um token:
        sudo GITHUB_TOKEN=ghp_seutoken bash install.sh" ;;
    *"not found"*|*"Repository not found"*)
      die "Repositório '${GITHUB_REPO}' não encontrado.
      Confira o nome ou use o seu fork:
        sudo GITHUB_REPO=seuusuario/seurepo bash install.sh" ;;
    *"Could not resolve host"*|*"unable to access"*|*"timed out"*)
      die "Sem conexão com ${GITHUB_HOST}.
      Teste na VPS:  curl -I https://${GITHUB_HOST}" ;;
    *)
      die "Não foi possível acessar https://${GITHUB_HOST}/${GITHUB_REPO}" ;;
  esac
}

# Tenta as branches candidatas até achar uma que realmente tenha o código
# (evita instalar um repositório que só tem README).
clone_repo() {
  check_github

  local candidatas=()
  if [[ -n "$REPO_BRANCH" ]]; then
    candidatas=("$REPO_BRANCH")
  else
    candidatas=("${FALLBACK_BRANCHES[@]}")
    local remotas b c vista
    remotas="$(git ls-remote --heads "$REPO_URL" 2>/dev/null \
               | sed 's#.*refs/heads/##' | grep -v '^$' || true)"
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      vista=""
      for c in "${candidatas[@]}"; do [[ "$c" == "$b" ]] && vista=1 && break; done
      [[ -z "$vista" ]] && candidatas+=("$b")
    done <<< "$remotas"
  fi

  local tmp br
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  for br in "${candidatas[@]}"; do
    git ls-remote --exit-code --heads "$REPO_URL" "$br" >/dev/null 2>&1 || continue
    info "Baixando o painel (branch ${br})..."
    rm -rf "${tmp}/repo"
    git clone --depth 1 -b "$br" "$REPO_URL" "${tmp}/repo" -q 2>/dev/null || continue

    if [[ -f "${tmp}/repo/app/main.py" ]]; then
      # Preserva o banco de uma instalação anterior.
      if [[ -d "$DATA_DIR" ]]; then
        info "Preservando dados existentes (contas e revendas)..."
        mv "$DATA_DIR" "${tmp}/data_backup"
      fi
      rm -rf "$INSTALL_DIR"
      mkdir -p "$(dirname "$INSTALL_DIR")"
      mv "${tmp}/repo" "$INSTALL_DIR"
      if [[ -d "${tmp}/data_backup" ]]; then
        rm -rf "$DATA_DIR"; mv "${tmp}/data_backup" "$DATA_DIR"
        ok "Dados anteriores restaurados."
      fi
      # Nunca deixa o token gravado no .git/config.
      [[ -n "$GITHUB_TOKEN" ]] && git -C "$INSTALL_DIR" remote set-url origin \
        "https://${GITHUB_HOST}/${GITHUB_REPO}.git" 2>/dev/null || true
      ok "Código obtido da branch '${br}'."
      return 0
    fi
    warn "A branch '${br}' não contém o painel; tentando a próxima..."
  done

  die "Não encontrei os arquivos do painel no repositório.
      Informe a branch correta, por exemplo:
      REPO_BRANCH=arena/01a038fb-4pluspainel bash install.sh"
}

fetch_code() {
  local origem; origem="$(dirname "$(readlink -f "$0")")"

  if [[ -f "${origem}/app/main.py" ]]; then
    # Rodando de dentro do repositório já clonado.
    info "Copiando arquivos de ${origem}..."
    mkdir -p "$INSTALL_DIR"
    cp -r "${origem}/app" "${origem}/requirements.txt" "$INSTALL_DIR"/
    [[ -f "${origem}/painel" ]]         && cp "${origem}/painel" "$INSTALL_DIR"/
    [[ -f "${origem}/diagnostico.sh" ]] && cp "${origem}/diagnostico.sh" "$INSTALL_DIR"/
    # Leva o .git junto para 'painel atualizar' funcionar depois.
    if [[ -d "${origem}/.git" && ! -d "${INSTALL_DIR}/.git" ]]; then
      cp -r "${origem}/.git" "${INSTALL_DIR}/.git" 2>/dev/null || true
      git -C "$INSTALL_DIR" remote set-url origin \
        "https://${GITHUB_HOST}/${GITHUB_REPO}.git" 2>/dev/null || true
    fi

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

# =========================================================================== #
#  6. AMBIENTE PYTHON
# =========================================================================== #

# Em Debian/Ubuntu o 'python3-venv' nem sempre traz o ensurepip: é preciso o
# pacote versionado (python3.8-venv, python3.11-venv, ...).
ensure_venv_support() {
  python3 -c 'import ensurepip' >/dev/null 2>&1 && return 0

  local pyver
  pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
  info "Instalando suporte a ambientes virtuais (python${pyver}-venv)..."
  export DEBIAN_FRONTEND=noninteractive
  [[ -n "$pyver" ]] && apt-get install -y -qq "python${pyver}-venv" >/dev/null 2>&1 || true
  python3 -c 'import ensurepip' >/dev/null 2>&1 && return 0

  apt-get install -y -qq python3-venv >/dev/null 2>&1 || true
  python3 -c 'import ensurepip' >/dev/null 2>&1 && return 0

  die "O Python desta VPS não tem suporte a ambientes virtuais.
      Instale manualmente e rode de novo:
        apt update && apt install -y python${pyver:-3}-venv"
}

setup_venv() {
  local venv="${INSTALL_DIR}/.venv"
  local py="${venv}/bin/python"

  ensure_venv_support

  # Recria do zero: um venv copiado/movido fica com os scripts apontando
  # para o caminho antigo e não executa.
  info "Criando ambiente virtual Python..."
  rm -rf "$venv"
  if ! python3 -m venv "$venv" 2>/tmp/4plus_venv.err; then
    warn "Falha ao criar o ambiente virtual:"
    sed 's/^/      /' /tmp/4plus_venv.err >&2 || true
    die "Não foi possível criar o ambiente virtual Python."
  fi
  [[ -x "$py" ]] || die "Ambiente virtual incompleto em ${venv}."

  # 'python -m pip' em vez de 'bin/pip': independe do shebang.
  info "Instalando dependências Python (pode levar alguns minutos)..."
  "$py" -m pip install --quiet --upgrade pip setuptools wheel 2>/dev/null \
    || warn "Não foi possível atualizar o pip; seguindo com a versão atual."

  if ! "$py" -m pip install --quiet -r "${INSTALL_DIR}/requirements.txt" 2>/tmp/4plus_pip.err; then
    warn "Falha ao instalar as dependências:"
    tail -n 15 /tmp/4plus_pip.err | sed 's/^/      /' >&2 || true
    die "Verifique se a VPS acessa pypi.org e tente de novo."
  fi

  # Confirma que o painel realmente importa dentro do venv.
  if ! ( cd "$INSTALL_DIR" && "$py" -c 'import fastapi, uvicorn, jinja2, itsdangerous' 2>/tmp/4plus_imp.err ); then
    warn "As dependências não puderam ser carregadas:"
    tail -n 10 /tmp/4plus_imp.err | sed 's/^/      /' >&2 || true
    die "Ambiente Python incompleto."
  fi

  local pv uv
  pv="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
  uv="$("$py" -c 'import uvicorn;print(uvicorn.__version__)' 2>/dev/null || echo '?')"
  ok "Ambiente Python pronto (Python ${pv}, uvicorn ${uv})."
}

# =========================================================================== #
#  7. ADMINISTRADOR
# =========================================================================== #

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
    # Reinstalação: mantém o acesso ativo e só troca a senha se veio uma nova.
    if password:
        execute("UPDATE admins SET password_hash = ?, role = 'admin', active = 1 WHERE id = ?",
                (hash_password(password), row["id"]))
    else:
        execute("UPDATE admins SET role = 'admin', active = 1 WHERE id = ?", (row["id"],))
else:
    execute("INSERT INTO admins (username, password_hash, role, user_limit, active, created_at)"
            " VALUES (?, ?, 'admin', 0, 1, ?)", (username, hash_password(password), now()))
PY
  ok "Administrador '${ADMIN_USER}' configurado."
}

# =========================================================================== #
#  8. SSH
# =========================================================================== #
#  As contas do painel autenticam por SENHA e usam shell /bin/false. Quase toda
#  VPS de nuvem vem com PasswordAuthentication desativado, o que tornaria essas
#  contas inutilizáveis. A regra vai para um arquivo próprio em sshd_config.d,
#  é validada com 'sshd -t' e, se algo der errado, o backup é restaurado.

configure_ssh() {
  local sshd=/etc/ssh/sshd_config
  local dropin_dir=/etc/ssh/sshd_config.d
  local dropin="${dropin_dir}/99-4pluspainel.conf"

  [[ -f "$sshd" ]] || { warn "sshd_config não encontrado; pulando ajuste do SSH."; return; }

  local SSHD_BIN="" cand
  for cand in /usr/sbin/sshd /sbin/sshd "$(command -v sshd 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { SSHD_BIN="$cand"; break; }
  done

  # 'sshd -t' exige o diretório de privilege separation, que pode não existir
  # logo após um boot; sem ele a validação falha e o ajuste seria revertido.
  [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null || true
  chmod 0755 /run/sshd 2>/dev/null || true

  # /bin/false precisa constar em /etc/shells para o pam_shells liberar o túnel.
  grep -qx '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
  grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

  [[ -f "${sshd}.4plus.bak" ]] || cp "$sshd" "${sshd}.4plus.bak"

  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd" && [[ -d "$dropin_dir" ]]; then
    cat > "$dropin" <<'EOF'
# 4Plus Painel — as contas do painel autenticam por senha.
# Remova este arquivo se desativar o painel.
PasswordAuthentication yes
EOF
    chmod 644 "$dropin"
    ok "SSH configurado via ${dropin}"
  else
    if grep -qiE '^\s*PasswordAuthentication\s+' "$sshd"; then
      sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/I' "$sshd"
    else
      printf '\n# 4Plus Painel\nPasswordAuthentication yes\n' >> "$sshd"
    fi
    ok "SSH configurado em ${sshd} (backup: ${sshd}.4plus.bak)"
  fi

  # Provedores costumam forçar 'no' em drop-ins que vêm depois na ordem.
  local f
  for f in "${dropin_dir}"/*.conf; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$dropin" ]] && continue
    if grep -qiE '^\s*PasswordAuthentication\s+no' "$f"; then
      sed -i -E 's/^(\s*PasswordAuthentication\s+no)/# \1  # desativado pelo 4Plus Painel/I' "$f"
      warn "Ajustado ${f} (PasswordAuthentication estava desativado)."
    fi
  done

  # Valida ANTES de recarregar — nunca deixa o SSH quebrado.
  if [[ -n "$SSHD_BIN" ]] && ! "$SSHD_BIN" -t 2>/tmp/4plus_sshd.err; then
    warn "Configuração do SSH ficou inválida; restaurando o backup."
    cp "${sshd}.4plus.bak" "$sshd"; rm -f "$dropin"
    cat /tmp/4plus_sshd.err >&2 || true
    warn "Ative PasswordAuthentication manualmente."
    return
  fi

  local svc
  for svc in ssh sshd; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
      break
    fi
  done

  # 'cmd | grep -q' retorna 141 (SIGPIPE) sob pipefail: captura antes de testar.
  local efetivo=""
  [[ -n "$SSHD_BIN" ]] && efetivo="$("$SSHD_BIN" -T 2>/dev/null || true)"
  if [[ "$efetivo" == *"passwordauthentication yes"* ]]; then
    ok "Autenticação por senha ativa — as contas do painel vão conectar."
  elif [[ "$efetivo" == *"passwordauthentication no"* ]]; then
    warn "PasswordAuthentication continua desativado."
    warn "Verifique se o provedor força a opção em outro arquivo."
  elif grep -qi '^\s*PasswordAuthentication\s\+yes' "$dropin" 2>/dev/null \
    || grep -qi '^\s*PasswordAuthentication\s\+yes' "$sshd" 2>/dev/null; then
    ok "Autenticação por senha configurada."
  else
    warn "Não foi possível confirmar PasswordAuthentication."
    warn "Verifique com: ${SSHD_BIN:-sshd} -T | grep -i passwordauth"
  fi
}

# =========================================================================== #
#  9. SERVIÇO SYSTEMD
# =========================================================================== #

create_service() {
  info "Criando serviço systemd..."

  # Em Debian/Ubuntu a unidade chama-se ssh.service; em RHEL, sshd.service.
  local ssh_unit="ssh.service"
  systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' && ssh_unit="sshd.service"

  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=${APP_NAME} — gerenciador de contas SSH
Documentation=https://${GITHUB_HOST}/${GITHUB_REPO}
# network-online garante IP configurado antes de abrir a porta no boot.
Wants=network-online.target
After=network-online.target ${ssh_unit}
# Sem limite de tentativas: numa VPS a porta ou a rede podem demorar após um
# reboot, e o padrão (5 tentativas em 10s) deixaria o painel morto.
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=PANEL_DATA_DIR=${DATA_DIR}
Environment=PANEL_PORT=${PORT}
Environment=PANEL_PUBLIC_HOST=${PUBLIC_HOST}
Environment=PYTHONUNBUFFERED=1
ExecStart=${INSTALL_DIR}/.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT}

Restart=always
RestartSec=5

# Encerramento limpo: o uvicorn finaliza as requisições em andamento.
KillSignal=SIGINT
TimeoutStopSec=20

# Endurecimento leve — nada que atrapalhe useradd/userdel/chpasswd.
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" -q 2>/dev/null || warn "Não foi possível habilitar no boot."
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl restart "$SERVICE"

  # Aguarda o estado real em vez de confiar num sleep fixo.
  local i estado
  for i in $(seq 1 20); do
    estado="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    [[ "$estado" == "active" || "$estado" == "failed" ]] && break
    sleep 1
  done

  if [[ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" != "active" ]]; then
    warn "O serviço não iniciou. Últimas linhas do log:"
    journalctl -u "$SERVICE" -n 25 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
    die "Falha ao iniciar. Rode 'painel doctor' para diagnosticar."
  fi

  # Confirma que a porta responde de fato.
  local respondeu=""
  for i in $(seq 1 15); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      respondeu=1; break
    fi
    sleep 1
  done

  if [[ -n "$respondeu" ]]; then
    ok "Serviço ativo e respondendo na porta ${PORT}."
  else
    warn "O serviço subiu, mas não respondeu em http://127.0.0.1:${PORT}/health"
    warn "Verifique com: painel logs"
  fi
}

# =========================================================================== #
#  10. COMANDOS E FIREWALL
# =========================================================================== #

install_cli() {
  if [[ -f "${INSTALL_DIR}/painel" ]]; then
    install -m 755 "${INSTALL_DIR}/painel" /usr/local/bin/painel
    ok "Comando 'painel' instalado."
  fi
}

install_diagnostico() {
  local origem; origem="$(dirname "$(readlink -f "$0")")"
  local f
  for f in "${origem}/diagnostico.sh" "${INSTALL_DIR}/diagnostico.sh"; do
    [[ -f "$f" ]] && install -m 755 "$f" /usr/local/bin/painel-diagnostico 2>/dev/null && return 0
  done
  return 0
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && ok "Porta ${PORT} liberada no UFW."
  fi
}

# =========================================================================== #
#  11. CREDENCIAIS E CONCLUSÃO
# =========================================================================== #

# Grava os dados de acesso: fechar o terminal não pode significar perdê-los.
save_credentials() {
  local ip="$1"
  local f="${INSTALL_DIR}/acesso.txt"
  cat > "$f" <<EOF
===== ${APP_NAME} — dados de acesso =====
Instalado em : $(date '+%d/%m/%Y %H:%M:%S')

Endereço : http://${ip}:${PORT}
Usuário  : ${ADMIN_USER}
Senha    : ${ADMIN_PASS}

Trocar a senha  : sudo painel senha
Ver este arquivo: sudo painel acesso
==========================================
EOF
  chmod 600 "$f" 2>/dev/null || true
}

finish() {
  local ip; ip="$(public_ip)"
  save_credentials "$ip"
  echo
  echo "${GREEN}${BOLD}   ╔══════════════════════════════════════════╗${NC}"
  echo "${GREEN}${BOLD}   ║        INSTALAÇÃO CONCLUÍDA! 🎉          ║${NC}"
  echo "${GREEN}${BOLD}   ╚══════════════════════════════════════════╝${NC}"
  echo
  echo "   ${BOLD}Acesse:${NC}  http://${ip}:${PORT}"
  echo "   ${BOLD}Usuário:${NC} ${ADMIN_USER}"
  echo "   ${BOLD}Senha:${NC}   ${ADMIN_PASS}"
  echo
  echo "   ${YELLOW}Guardado em ${INSTALL_DIR}/acesso.txt — veja com: sudo painel acesso${NC}"
  echo
  echo "   ${BOLD}Origem do código:${NC} https://${GITHUB_HOST}/${GITHUB_REPO}"
  echo "   (atualize depois com: sudo painel atualizar)"
  echo
  echo "   ${BOLD}Digite 'painel' para abrir o menu no terminal.${NC}"
  echo
  echo "     painel acesso      — ver IP, usuário e senha"
  echo "     painel status      — situação do serviço"
  echo "     painel logs        — acompanhar o log"
  echo "     painel doctor      — diagnosticar problemas"
  echo "     painel desinstalar — remover o painel"
  echo
}

# =========================================================================== #
#  12. EXECUÇÃO
# =========================================================================== #

main() {
  start_logging
  banner

  # -- verificações --------------------------------------------------------
  check_root
  check_os
  ask_config
  install_packages
  check_python_version
  resolve_public_host

  # -- instalação ----------------------------------------------------------
  fetch_code
  setup_venv
  create_admin
  configure_ssh
  create_service

  # -- finalização ---------------------------------------------------------
  install_cli
  install_diagnostico
  open_firewall
  finish
}

main "$@"
