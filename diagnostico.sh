#!/usr/bin/env bash
# 4Plus Painel — diagnóstico da VPS
#
# Verifica se a VPS tem tudo o que o instalador precisa, SEM instalar nada.
# Roda sozinho: não depende do painel nem de nenhum outro arquivo.
#
#   sudo bash diagnostico.sh
#
# Propositalmente sem 'set -e': o objetivo é testar tudo e mostrar o
# resultado completo, mesmo que alguma verificação falhe.

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

FALHAS=0
AVISOS=0

ok()    { echo "  ${G}[OK]${NC}   $*"; }
falha() { echo "  ${R}[FALHA]${NC} $*"; FALHAS=$((FALHAS+1)); }
aviso() { echo "  ${Y}[AVISO]${NC} $*"; AVISOS=$((AVISOS+1)); }
titulo(){ echo; echo "${B}${BOLD}$*${NC}"; }

echo
echo "${B}${BOLD}=========================================${NC}"
echo "${B}${BOLD}   4PLUS PAINEL — DIAGNÓSTICO DA VPS     ${NC}"
echo "${B}${BOLD}=========================================${NC}"

# --------------------------------------------------------------------------- #
titulo "1. Sistema"
# --------------------------------------------------------------------------- #
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "  Sistema : ${PRETTY_NAME:-desconhecido}"
else
  aviso "/etc/os-release não encontrado — distribuição desconhecida."
fi
echo "  Kernel  : $(uname -srm)"
echo "  Arquit. : $(uname -m)"

if [[ $EUID -eq 0 ]]; then
  ok "Rodando como root."
else
  falha "NÃO está como root. Use: sudo bash diagnostico.sh"
fi

# --------------------------------------------------------------------------- #
titulo "2. Recursos"
# --------------------------------------------------------------------------- #
disco_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "$disco_kb" ]]; then
  disco_mb=$((disco_kb / 1024))
  echo "  Disco livre : ${disco_mb} MB"
  if (( disco_mb < 500 )); then
    falha "Menos de 500 MB livres — o pip precisa de espaço para instalar."
  else
    ok "Espaço em disco suficiente."
  fi
fi

ram_mb="$(free -m 2>/dev/null | awk '/Mem:/{print $2}')"
if [[ -n "$ram_mb" ]]; then
  echo "  Memória RAM : ${ram_mb} MB"
  if (( ram_mb < 400 )); then
    aviso "RAM baixa. Se o pip travar, ative swap:"
    echo "          fallocate -l 1G /swapfile && chmod 600 /swapfile"
    echo "          mkswap /swapfile && swapon /swapfile"
  else
    ok "Memória suficiente."
  fi
fi

# --------------------------------------------------------------------------- #
titulo "3. Python"
# --------------------------------------------------------------------------- #
if command -v python3 >/dev/null 2>&1; then
  pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  echo "  Versão : $(python3 -V 2>&1)"
  maj="${pyver%%.*}"; min="${pyver##*.}"
  if (( maj > 3 || (maj == 3 && min >= 8) )); then
    ok "Python ${pyver} é compatível (mínimo 3.8)."
  else
    falha "Python ${pyver} é antigo demais. O painel precisa de 3.8+."
  fi

  if python3 -c 'import ensurepip' >/dev/null 2>&1; then
    ok "Suporte a ambiente virtual (ensurepip) presente."
  else
    falha "Falta o pacote venv. Instale com: apt install -y python${pyver}-venv"
  fi

  # Teste real: cria um venv descartável.
  tmpv="$(mktemp -d)"
  if python3 -m venv "${tmpv}/v" >"${tmpv}/erro.txt" 2>&1; then
    ok "Criação de ambiente virtual funcionou."
  else
    falha "Não consegue criar ambiente virtual. Erro:"
    sed 's/^/          /' "${tmpv}/erro.txt" | head -6
  fi
  rm -rf "$tmpv"
else
  falha "python3 não está instalado. Instale com: apt install -y python3"
fi

# --------------------------------------------------------------------------- #
titulo "4. Ferramentas necessárias"
# --------------------------------------------------------------------------- #
for prog in git curl useradd chpasswd usermod systemctl; do
  if command -v "$prog" >/dev/null 2>&1; then
    ok "$prog encontrado"
  else
    case "$prog" in
      git)        falha "git ausente — instale: apt install -y git" ;;
      curl)       falha "curl ausente — instale: apt install -y curl" ;;
      systemctl)  falha "systemd ausente — o painel roda como serviço systemd." ;;
      *)          falha "$prog ausente — instale: apt install -y passwd" ;;
    esac
  fi
done

# --------------------------------------------------------------------------- #
titulo "5. Conectividade"
# --------------------------------------------------------------------------- #
testa_url() {
  local nome="$1" url="$2" dica="$3"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$url" 2>/dev/null)"
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    ok "${nome} acessível (HTTP ${code})"
  else
    falha "${nome} INACESSÍVEL — ${dica}"
  fi
}
testa_url "GitHub"  "https://github.com"     "sem isso o git clone falha"
testa_url "PyPI"    "https://pypi.org/simple/" "sem isso o pip não instala as dependências"

# Testa o repositório de verdade, não apenas o site do GitHub.
GITHUB_REPO="${GITHUB_REPO:-Alefsousa5/4pluspainel-}"
REPO_TESTE="https://github.com/${GITHUB_REPO}.git"
[[ -n "${GITHUB_TOKEN:-}" ]] && REPO_TESTE="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

if command -v git >/dev/null 2>&1; then
  saida_git="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REPO_TESTE" 2>&1)"
  if [[ $? -eq 0 ]]; then
    nb="$(echo "$saida_git" | grep -c 'refs/heads/')"
    ok "Repositório ${GITHUB_REPO} acessível (${nb} branch(es))."
    if echo "$saida_git" | grep -q 'refs/heads/main'; then
      echo "         branches: $(echo "$saida_git" | sed 's#.*refs/heads/##' | tr '\n' ' ')"
    fi
  else
    case "$saida_git" in
      *"Authentication"*|*"could not read Username"*)
        falha "Repositório privado. Use: sudo GITHUB_TOKEN=ghp_seutoken bash install.sh" ;;
      *"not found"*)
        falha "Repositório '${GITHUB_REPO}' não encontrado. Confira o nome." ;;
      *)
        falha "Não foi possível acessar ${GITHUB_REPO}:"
        echo "$saida_git" | head -3 | sed 's/^/          /' ;;
    esac
  fi
fi

if apt-get update -qq >/dev/null 2>&1; then
  ok "Repositórios apt respondendo."
else
  aviso "apt-get update falhou — os repositórios da VPS podem estar com problema."
fi

# --------------------------------------------------------------------------- #
titulo "6. SSH"
# --------------------------------------------------------------------------- #
SSHD_BIN=""
for c in /usr/sbin/sshd /sbin/sshd "$(command -v sshd 2>/dev/null)"; do
  [[ -n "$c" && -x "$c" ]] && { SSHD_BIN="$c"; break; }
done

if [[ -n "$SSHD_BIN" ]]; then
  ok "servidor SSH instalado (${SSHD_BIN})"
  [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null
  efetivo="$("$SSHD_BIN" -T 2>/dev/null)"
  if [[ "$efetivo" == *"passwordauthentication yes"* ]]; then
    ok "Autenticação por senha ATIVA (contas do painel vão conectar)."
  elif [[ "$efetivo" == *"passwordauthentication no"* ]]; then
    aviso "Autenticação por senha DESATIVADA. O instalador corrige isso."
  else
    aviso "Não foi possível ler a configuração do SSH."
  fi
  porta_ssh="$(echo "$efetivo" | awk '/^port /{print $2}' | tr '\n' ' ')"
  [[ -n "$porta_ssh" ]] && echo "  Portas SSH : ${porta_ssh}"
else
  falha "servidor SSH ausente — instale: apt install -y openssh-server"
fi

# --------------------------------------------------------------------------- #
titulo "7. Porta do painel"
# --------------------------------------------------------------------------- #
PORTA="${1:-8080}"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":${PORTA} "; then
    falha "A porta ${PORTA} JÁ ESTÁ EM USO. Escolha outra: PANEL_PORT=8090"
  else
    ok "Porta ${PORTA} livre."
  fi
else
  aviso "Comando 'ss' ausente; não foi possível checar a porta ${PORTA}."
fi

ip_pub="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"
ip_local="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$ip_pub" ]]   && echo "  IP público : ${ip_pub}"
[[ -n "$ip_local" ]] && echo "  IP local   : ${ip_local}"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  aviso "UFW está ativo. O instalador libera a porta, mas confirme depois."
fi

# --------------------------------------------------------------------------- #
titulo "8. Instalação existente"
# --------------------------------------------------------------------------- #
if [[ -d /opt/4pluspainel ]]; then
  echo "  Painel já instalado em /opt/4pluspainel"
  estado="$(systemctl is-active 4pluspainel 2>/dev/null)"
  echo "  Serviço : ${estado:-não registrado}"
  [[ -f /opt/4pluspainel/data/painel.db ]] && ok "Banco de dados presente (será preservado)."
else
  echo "  Nenhuma instalação anterior."
fi

# --------------------------------------------------------------------------- #
echo
echo "${B}${BOLD}=========================================${NC}"
if (( FALHAS == 0 )); then
  echo "  ${G}${BOLD}TUDO CERTO PARA INSTALAR${NC}"
  [[ $AVISOS -gt 0 ]] && echo "  (${AVISOS} aviso(s) — não impedem a instalação)"
  echo
  echo "  Prossiga com:  ${BOLD}sudo bash install.sh${NC}"
else
  echo "  ${R}${BOLD}${FALHAS} PROBLEMA(S) ENCONTRADO(S)${NC}"
  echo
  echo "  Resolva os itens marcados como ${R}[FALHA]${NC} acima e rode de novo."
  echo "  Se não souber como, mande esta saída inteira para análise."
fi
echo "${B}${BOLD}=========================================${NC}"
echo

exit 0
