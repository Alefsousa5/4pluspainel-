# 4G Plus Painel

Painel web responsivo para administração/monitoramento do **4G Plus**, com script de instalação pronto para VPS Ubuntu usando este repositório no GitHub/Arena.

## O que está incluído

- Painel web em Node.js, sem dependências externas obrigatórias.
- API simples de saúde/status: `/health`, `/api/status` e `/api/metrics`.
- Script de instalação para VPS Ubuntu com:
  - Node.js 20 LTS;
  - Git;
  - Nginx como proxy reverso;
  - serviço `systemd` para iniciar automaticamente;
  - configuração opcional de domínio e SSL.
- Workflow básico do GitHub Actions para validar o servidor.

## Instalação rápida na VPS Ubuntu

Acesse sua VPS via SSH e rode:

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo bash install-ubuntu.sh
```

Com domínio:

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo bash install-ubuntu.sh --domain painel.seudominio.com
```

Com domínio e SSL automático:

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo SSL_EMAIL="seuemail@seudominio.com" bash install-ubuntu.sh --domain painel.seudominio.com --ssl
```

> Antes de ativar SSL, aponte o DNS do domínio para o IP da VPS.

## Opções do instalador

```bash
sudo bash scripts/install-ubuntu.sh [opções]
```

| Opção | Exemplo | Descrição |
| --- | --- | --- |
| `--domain` | `--domain painel.site.com` | Configura Nginx para o domínio informado. Sem domínio, usa o IP da VPS. |
| `--ssl` | `--ssl` | Instala Certbot e tenta ativar HTTPS para o domínio. |
| `--port` | `--port 3000` | Porta interna do Node.js. Padrão: `3000`. |
| `--repo` | `--repo https://github.com/Alefsousa5/4pluspainel-.git` | URL do repositório Git. |
| `--branch` | `--branch arena/01a039e9-4pluspainel` | Branch que será implantada. |
| `--dir` | `--dir /opt/4pluspainel` | Diretório de instalação. |
| `--no-nginx` | `--no-nginx` | Instala apenas o serviço Node.js, sem configurar Nginx. |

Também é possível configurar por variáveis de ambiente:

```bash
APP_PORT=4000 APP_DIR=/srv/4pluspainel sudo -E bash scripts/install-ubuntu.sh
```

## Atualizar o painel na VPS

Depois de instalar, para atualizar com a versão mais recente da branch:

```bash
sudo bash /opt/4pluspainel/scripts/update-ubuntu.sh
```

Ou manualmente:

```bash
cd /opt/4pluspainel
sudo git fetch origin arena/01a039e9-4pluspainel
sudo git reset --hard origin/arena/01a039e9-4pluspainel
sudo npm ci --omit=dev --no-audit --no-fund || sudo npm install --omit=dev --no-audit --no-fund
sudo systemctl restart 4pluspainel
```

## Comandos úteis na VPS

```bash
sudo systemctl status 4pluspainel
sudo journalctl -u 4pluspainel -f
sudo systemctl restart 4pluspainel
sudo nginx -t
```

## Desenvolvimento local

```bash
npm install
npm start
```

Abra: <http://localhost:3000>

## Repositório

- GitHub: <https://github.com/Alefsousa5/4pluspainel->
- Branch Arena: `arena/01a039e9-4pluspainel`
