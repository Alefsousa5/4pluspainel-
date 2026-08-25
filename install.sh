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
# --------------------------------------------------------------------------- #
# GITHUB — REPOSITÓRIO DE ORIGEM DO PAINEL
# --------------------------------------------------------------------------- #
#
#   Repositório : https://github.com/Alefsousa5/4pluspainel-
#   Clone (git) : https://github.com/Alefsousa5/4pluspainel-.git
#
# É daqui que o painel é baixado na instalação e atualizado depois
# (sudo painel atualizar).
#
# Para usar OUTRO repositório (por exemplo o seu fork), edite a linha
# GITHUB_REPO abaixo ou passe por variável, sem precisar alterar o script:
#
#   sudo GITHUB_REPO=seuusuario/seurepo bash install.sh
#   sudo GITHUB_TOKEN=ghp_seutoken     bash install.sh   # repositório privado
#
# --------------------------------------------------------------------------- #

# >>> Repositório do painel no GitHub (usuário/repositório) <<<
GITHUB_REPO="${GITHUB_REPO:-Alefsousa5/4pluspainel-}"

# Host do GitHub (mude apenas se usar GitHub Enterprise).
GITHUB_HOST="${GITHUB_HOST:-github.com}"

# Token opcional, apenas para repositório privado (nunca é gravado em disco).
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# URL final usada pelo git. Ex.: https://github.com/Alefsousa5/4pluspainel-.git
if [[ -n "${REPO_URL:-}" ]]; then
  : # URL completa informada manualmente tem prioridade
elif [[ -n "$GITHUB_TOKEN" ]]; then
  REPO_URL="https://${GITHUB_TOKEN}@${GITHUB_HOST}/${GITHUB_REPO}.git"
else
  REPO_URL="https://${GITHUB_HOST}/${GITHUB_REPO}.git"
fi

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
  local line="$1" cmd="${BASH_COMMAND:-?}"
  if [[ "$DIED" == "1" ]]; then
    # Erro já explicado por die(); só aponta o log.
    [[ -n "${LOGFILE:-}" && -f "${LOGFILE:-}" ]] && \
      echo "    Log completo em: ${LOGFILE}" >&2
    exit 1
  fi
  echo "${RED}[x]${NC} Falha inesperada na linha ${line}." >&2
  echo "    Comando: ${cmd}" >&2
  [[ -n "${LOGFILE:-}" && -f "${LOGFILE:-}" ]] && \
    echo "    Log completo em: ${LOGFILE}" >&2
  echo >&2
  echo "    Para descobrir a causa, rode:  ${BOLD}sudo bash diagnostico.sh${NC}" >&2
  echo "    Ele verifica Python, rede, disco, porta e permissões." >&2
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
  echo "   Repositório: ${BOLD}https://${GITHUB_HOST}/${GITHUB_REPO}${NC}"
  echo
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

# Existe um terminal para perguntar ao usuário?
# Com 'bash <(curl ...)' ou 'curl ... | bash' o stdin NÃO é um terminal: ler
# dele retorna EOF na hora. Nesse caso as perguntas são feitas em /dev/tty,
# e se nem isso existir a instalação segue com os valores padrão.
TTY_IN=""
detect_tty() {
  if [[ -t 0 ]]; then
    TTY_IN="/dev/stdin"
  elif [[ -r /dev/tty ]] && : 2>/dev/null >/dev/tty; then
    TTY_IN="/dev/tty"
  else
    TTY_IN=""
  fi
}

# ask <variável> <pergunta> <padrão>
# Nunca aborta: sem terminal, assume o padrão.
ask() {
  local __var="$1" __prompt="$2" __default="$3" __reply=""
  if [[ -z "$TTY_IN" ]]; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  read -rp "$__prompt" __reply <"$TTY_IN" || __reply=""
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# ask_secret <variável> <pergunta>  (não ecoa o que é digitado)
ask_secret() {
  local __var="$1" __prompt="$2" __reply=""
  if [[ -z "$TTY_IN" ]]; then
    printf -v "$__var" '%s' ""
    return 0
  fi
  read -rsp "$__prompt" __reply <"$TTY_IN" || __reply=""
  echo
  printf -v "$__var" '%s' "$__reply"
}

ask_config() {
  detect_tty

  if [[ -n "${PANEL_UNATTENDED:-}" || -z "$TTY_IN" ]]; then
    PORT="${PANEL_PORT:-$DEFAULT_PORT}"
    ADMIN_USER="${PANEL_ADMIN:-admin}"
    ADMIN_PASS="${PANEL_ADMIN_PASS:-$(gen_password)}"
    if [[ -z "$TTY_IN" && -z "${PANEL_UNATTENDED:-}" ]]; then
      info "Sem terminal interativo — usando os valores padrão."
      info "Para escolher porta e senha, baixe o script e rode:"
      info "  curl -sSLO <url>/install.sh && sudo bash install.sh"
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

# Confere o acesso ao GitHub antes de tentar baixar, para separar um problema
# de rede/credencial de um problema do próprio painel.
check_github() {
  local mostrar="${REPO_URL/${GITHUB_TOKEN}@/***@}"
  info "Verificando acesso ao GitHub (${GITHUB_REPO})..."

  if ! command -v git >/dev/null 2>&1; then
    die "git não está instalado. Instale com: apt install -y git"
  fi

  # git ls-remote resolve autenticação, DNS e TLS de uma vez só.
  # Obs.: sob 'set -e' uma atribuição que falha aborta a função antes de
  # chegar no 'rc=$?'. O '|| true' garante que o erro seja tratado aqui.
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
      Se o repositório for privado, informe um token:
        sudo GITHUB_TOKEN=ghp_seutoken bash install.sh" ;;
    *"not found"*|*"Repository not found"*)
      die "Repositório '${GITHUB_REPO}' não encontrado.
      Confira o nome ou use o seu fork:
        sudo GITHUB_REPO=seuusuario/seurepo bash install.sh" ;;
    *"Could not resolve host"*|*"unable to access"*|*"timed out"*)
      die "Sem conexão com o GitHub (${GITHUB_HOST}).
      Teste na VPS:  curl -I https://${GITHUB_HOST}
      Verifique DNS, firewall de saída ou proxy do provedor." ;;
    *)
      die "Não foi possível acessar ${mostrar}" ;;
  esac
}

# Baixa o painel testando as branches candidatas até achar uma que
# realmente contenha o código (evita instalar um repositório só com README).
clone_repo() {
  check_github

  local candidates=()
  if [[ -n "$REPO_BRANCH" ]]; then
    candidates=("$REPO_BRANCH")
  else
    candidates=("${FALLBACK_BRANCHES[@]}")
    # Descobre TODAS as branches do repositório: assim o instalador acha o
    # código mesmo que ele esteja numa branch que não conhecemos de antemão.
    local remote_branches
    remote_branches="$(git ls-remote --heads "$REPO_URL" 2>/dev/null \
                       | sed 's#.*refs/heads/##' | grep -v '^$' || true)"
    local b
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      # evita repetir as candidatas já listadas
      local seen="" c
      for c in "${candidates[@]}"; do [[ "$c" == "$b" ]] && seen=1 && break; done
      [[ -z "$seen" ]] && candidates+=("$b")
    done <<< "$remote_branches"
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
      # Nunca deixa o token gravado no .git/config da instalação.
      if [[ -n "$GITHUB_TOKEN" ]]; then
        git -C "$INSTALL_DIR" remote set-url origin \
          "https://${GITHUB_HOST}/${GITHUB_REPO}.git" 2>/dev/null || true
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
    [[ -f "${src}/diagnostico.sh" ]] && cp "${src}/diagnostico.sh" "$INSTALL_DIR"/
    # Leva o .git junto para que 'painel atualizar' funcione depois.
    if [[ -d "${src}/.git" && ! -d "${INSTALL_DIR}/.git" ]]; then
      cp -r "${src}/.git" "${INSTALL_DIR}/.git" 2>/dev/null || true
      # Garante que o remote aponte para o GitHub, sem token.
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

# Instala o pacote venv correspondente à versão do Python presente.
# Em Debian/Ubuntu o 'python3-venv' nem sempre traz o ensurepip: é preciso o
# pacote versionado (python3.8-venv, python3.11-venv, ...).
# O painel exige Python 3.8 ou superior. Falhar aqui, com mensagem clara, é
# muito melhor do que instalar e só descobrir o problema ao usar o painel.
check_python_version() {
  local ver major minor
  ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
  [[ -n "$ver" ]] || die "Python 3 não encontrado. Instale com: apt install -y python3"
  major="${ver%%.*}"; minor="${ver##*.}"
  if (( major < 3 || (major == 3 && minor < 8) )); then
    die "Python ${ver} é antigo demais — o painel precisa de 3.8 ou superior.
      Atualize o sistema ou instale um Python mais novo antes de continuar."
  fi
  ok "Python ${ver} detectado."
}

ensure_venv_support() {
  local pyver
  pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"

  if python3 -c 'import ensurepip' >/dev/null 2>&1; then
    return 0
  fi

  info "Instalando suporte a ambientes virtuais (python${pyver}-venv)..."
  export DEBIAN_FRONTEND=noninteractive
  if [[ -n "$pyver" ]]; then
    apt-get install -y -qq "python${pyver}-venv" >/dev/null 2>&1 || true
  fi
  python3 -c 'import ensurepip' >/dev/null 2>&1 && return 0

  apt-get install -y -qq python3-venv >/dev/null 2>&1 || true
  python3 -c 'import ensurepip' >/dev/null 2>&1 && return 0

  die "O Python desta VPS não tem suporte a ambientes virtuais.
      Instale manualmente e rode o instalador de novo:
        apt update && apt install -y python${pyver:-3}-venv"
}

setup_venv() {
  local venv="${INSTALL_DIR}/.venv"
  local py="${venv}/bin/python"

  check_python_version
  ensure_venv_support

  # Recria do zero: um venv copiado/movido de outro caminho fica com os
  # scripts apontando para o diretório antigo e nada funciona.
  info "Criando ambiente virtual Python..."
  rm -rf "$venv"
  if ! python3 -m venv "$venv" 2>/tmp/4plus_venv.err; then
    warn "Falha ao criar o ambiente virtual:"
    sed 's/^/      /' /tmp/4plus_venv.err >&2 || true
    die "Não foi possível criar o ambiente virtual Python."
  fi

  [[ -x "$py" ]] || die "Ambiente virtual criado de forma incompleta em ${venv}."

  # Usa 'python -m pip' em vez do script bin/pip: independe do shebang.
  info "Instalando dependências Python (pode levar alguns minutos)..."
  "$py" -m pip install --quiet --upgrade pip setuptools wheel 2>/dev/null \
    || warn "Não foi possível atualizar o pip; seguindo com a versão atual."

  if ! "$py" -m pip install --quiet -r "${INSTALL_DIR}/requirements.txt" 2>/tmp/4plus_pip.err; then
    warn "Falha ao instalar as dependências. Detalhe:"
    tail -n 15 /tmp/4plus_pip.err | sed 's/^/      /' >&2 || true
    die "Não foi possível instalar as dependências Python.
      Verifique a conexão da VPS com a internet (pypi.org) e tente de novo."
  fi

  # Confirma que o painel realmente importa dentro do venv.
  if ! (cd "$INSTALL_DIR" && "$py" -c 'import fastapi, uvicorn, jinja2, itsdangerous' 2>/tmp/4plus_imp.err); then
    warn "As dependências não puderam ser carregadas:"
    tail -n 10 /tmp/4plus_imp.err | sed 's/^/      /' >&2 || true
    die "Ambiente Python incompleto."
  fi

  local pyver uvi
  pyver="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "?")"
  uvi="$("$py" -c 'import uvicorn;print(uvicorn.__version__)' 2>/dev/null || echo "?")"
  ok "Ambiente Python pronto (Python ${pyver}, uvicorn ${uvi})."
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

  # O sshd (inclusive 'sshd -t') exige o diretório de privilege separation,
  # que pode não existir logo após um boot. Sem ele a validação falha e a
  # configuração seria revertida sem necessidade.
  [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null || true
  chmod 0755 /run/sshd 2>/dev/null || true

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
  local effective=""""
  [[ -n "$SSHD_BIN" ]] && effective="$("$SSHD_BIN" -T 2>/dev/null || true)"

  if [[ "$effective" == *"passwordauthentication yes"* ]]; then
    ok "Autenticação por senha ativa — as contas do painel vão conectar."
  elif [[ "$effective" == *"passwordauthentication no"* ]]; then
    warn "PasswordAuthentication continua desativado."
    warn "As contas do painel não conseguirão conectar até isso ser corrigido."
    warn "Verifique se o provedor força a opção em outro arquivo de configuração."
  else
    # sshd -T não pôde ser executado; confere pelo arquivo que acabamos de criar.
    if grep -qi '^\s*PasswordAuthentication\s\+yes' "$dropin" 2>/dev/null \
       || grep -qi '^\s*PasswordAuthentication\s\+yes' "$sshd" 2>/dev/null; then
      ok "Autenticação por senha configurada."
      info "Confirme após um reboot com: ${SSHD_BIN:-sshd} -T | grep -i passwordauth"
    else
      warn "Não foi possível confirmar PasswordAuthentication."
      warn "Verifique com: ${SSHD_BIN:-sshd} -T | grep -i passwordauth"
    fi
  fi
}

create_service() {
  info "Criando serviço systemd..."

  # Em Debian/Ubuntu a unidade do SSH chama-se ssh.service; em RHEL/CentOS,
  # sshd.service. Declarar uma que não existe faz o systemd ignorar a ordem.
  local ssh_unit="ssh.service"
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    ssh_unit="sshd.service"
  fi

  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=${APP_NAME} — gerenciador de contas SSH
Documentation=https://github.com/Alefsousa5/4pluspainel-
# network-online garante IP configurado antes de abrir a porta no boot.
Wants=network-online.target
After=network-online.target ${ssh_unit}
# Sem limite de tentativas: uma VPS pode demorar a liberar a porta ou a rede,
# e o padrão (5 tentativas em 10s) deixaria o painel morto após um reboot.
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

# Endurecimento leve. Nada que impeça useradd/userdel/chpasswd: o painel
# gerencia contas do sistema e precisa enxergar /home e /etc normalmente.
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" -q 2>/dev/null || warn "Não foi possível habilitar o serviço no boot."
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl restart "$SERVICE"

  # Aguarda o serviço responder de fato, em vez de confiar num sleep fixo.
  local i state
  for i in $(seq 1 20); do
    state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    [[ "$state" == "active" ]] && break
    [[ "$state" == "failed" ]] && break
    sleep 1
  done

  if [[ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" != "active" ]]; then
    warn "O serviço não iniciou. Últimas linhas do log:"
    journalctl -u "$SERVICE" -n 25 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
    die "Falha ao iniciar o serviço. Rode 'painel doctor' para diagnosticar."
  fi

  # Confirma que a porta está realmente aceitando conexões.
  local ok_http=""
  for i in $(seq 1 15); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      ok_http="1"; break
    fi
    sleep 1
  done

  if [[ -n "$ok_http" ]]; then
    ok "Serviço ativo e respondendo na porta ${PORT}."
  else
    warn "O serviço subiu, mas não respondeu em http://127.0.0.1:${PORT}/health"
    warn "Verifique com: painel logs"
  fi
}

install_diagnostico() {
  local src; src="$(dirname "$(readlink -f "$0")")"
  local f
  for f in "${src}/diagnostico.sh" "${INSTALL_DIR}/diagnostico.sh"; do
    if [[ -f "$f" ]]; then
      install -m 755 "$f" /usr/local/bin/painel-diagnostico 2>/dev/null && return 0
    fi
  done
  return 0
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

# Guarda os dados de acesso em disco: se o terminal for fechado, as
# credenciais não se perdem. Arquivo legível apenas pelo root.
save_credentials() {
  local ip="$1"
  local f="${INSTALL_DIR}/acesso.txt"
  cat > "$f" <<EOF
===== 4Plus Painel — dados de acesso =====
Instalado em : $(date '+%d/%m/%Y %H:%M:%S')

Endereço : http://${ip}:${PORT}
Usuário  : ${ADMIN_USER}
Senha    : ${ADMIN_PASS}

Trocar a senha : sudo painel senha
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
  echo "   ${YELLOW}Anote a senha. Se precisar, ela também fica guardada em${NC}"
  echo "   ${YELLOW}${INSTALL_DIR}/acesso.txt — veja com: sudo painel acesso${NC}"
  echo
  echo "   ${BOLD}Origem do código:${NC} https://${GITHUB_HOST}/${GITHUB_REPO}"
  echo "   (atualize depois com: sudo painel atualizar)"
  echo
  echo "   Comandos úteis:"
  echo "     painel status      — situação do serviço"
  echo "     painel restart     — reiniciar"
  echo "     painel logs        — acompanhar o log"
  echo "     painel senha       — trocar a senha do admin"
  echo "     painel desinstalar — remover o painel"
  echo
}

# Tudo o que aparece na tela também vai para um arquivo de log. Se algo der
# errado, esse arquivo tem o comando exato que falhou e a saída completa.
LOGFILE="/var/log/4pluspainel-install.log"
start_logging() {
  : > "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/4pluspainel-install.log"
  {
    echo "===== 4Plus Painel — instalação em $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "sistema : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-desconhecido}")"
    echo "kernel  : $(uname -srm)"
    echo "python  : $(python3 -V 2>&1)"
    echo "disco   : $(df -h / 2>/dev/null | awk 'NR==2{print $4" livre de "$2}')"
    echo "memoria : $(free -m 2>/dev/null | awk '/Mem:/{print $7"MB disponivel"}')"
    echo "=================================================================="
  } >> "$LOGFILE" 2>&1
  exec > >(tee -a "$LOGFILE") 2>&1
}

main() {
  start_logging
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
  install_diagnostico
  open_firewall
  finish
}

main "$@"
