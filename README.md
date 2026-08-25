# 4G Plus SSH Painel

Painel web para **gerenciar usuários SSH** e **alocar contas em servidores SSH/VPS Ubuntu**.

O projeto foi preparado para o repositório GitHub/Arena e inclui um instalador automático para VPS Ubuntu.

## Funções do painel

- Login administrativo por `ADMIN_TOKEN`.
- Criar usuários SSH com:
  - usuário;
  - senha manual ou gerada automaticamente;
  - validade em dias;
  - limite de conexões simultâneas;
  - alocação automática no servidor com mais vagas livres.
- Bloquear, ativar, renovar validade, trocar senha e excluir usuários SSH.
- Cadastrar servidores SSH/VPS para alocação.
- Servidor local com provisionamento real de usuários Linux via helper seguro.
- Servidores remotos em modo alocação/controle manual.
- Banco local JSON em `/var/lib/4pluspainel/db.json`.
- Nginx, systemd, OpenSSH Server e SSL opcional.

> Observação: o provisionamento automático cria usuários Linux reais apenas no servidor onde o painel está instalado. Servidores remotos cadastrados são usados para alocação/organização; para provisionar remoto automaticamente, instale o painel/agente também no servidor remoto ou faça a criação manual nele.

## Instalação rápida na VPS Ubuntu

Acesse sua VPS via SSH e rode:

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo bash install-ubuntu.sh
```

No final da instalação será mostrado:

- URL do painel;
- token de administrador;
- host e porta SSH que serão entregues aos clientes.

Guarde o **Token admin**, pois ele será pedido na tela de login.

## Instalar com domínio

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo bash install-ubuntu.sh --domain painel.seudominio.com
```

## Instalar com domínio e SSL

Antes, aponte o DNS do domínio para o IP da VPS. Depois rode:

```bash
curl -fsSL -o install-ubuntu.sh "https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a039e9-4pluspainel/scripts/install-ubuntu.sh"
sudo SSL_EMAIL="seuemail@seudominio.com" bash install-ubuntu.sh --domain painel.seudominio.com --ssl
```

## Personalizar host/porta SSH entregue aos clientes

Se sua VPS usa outra porta SSH ou você quer entregar um host específico:

```bash
sudo bash install-ubuntu.sh --ssh-host ssh.seudominio.com --ssh-port 22 --capacity 300
```

## Opções do instalador

```bash
sudo bash scripts/install-ubuntu.sh [opções]
```

| Opção | Exemplo | Descrição |
| --- | --- | --- |
| `--domain` | `--domain painel.site.com` | Configura Nginx para o domínio informado. Sem domínio, usa o IP da VPS. |
| `--ssl` | `--ssl` | Instala Certbot e tenta ativar HTTPS para o domínio. |
| `--port` | `--port 3000` | Porta interna do Node.js. Padrão: `3000`. |
| `--ssh-host` | `--ssh-host ssh.site.com` | Host/IP mostrado nas credenciais SSH criadas. |
| `--ssh-port` | `--ssh-port 22` | Porta SSH mostrada nas credenciais. |
| `--capacity` | `--capacity 300` | Capacidade inicial do servidor local. |
| `--repo` | `--repo https://github.com/Alefsousa5/4pluspainel-.git` | URL do repositório Git. |
| `--branch` | `--branch arena/01a039e9-4pluspainel` | Branch implantada. |
| `--dir` | `--dir /opt/4pluspainel` | Diretório de instalação da aplicação. |
| `--data-dir` | `--data-dir /var/lib/4pluspainel` | Diretório do banco JSON. |
| `--no-nginx` | `--no-nginx` | Instala apenas o serviço Node.js, sem configurar Nginx. |
| `--no-system-ssh` | `--no-system-ssh` | Não cria usuários Linux reais; salva apenas no painel. |
| `--no-password-ssh` | `--no-password-ssh` | Não altera configuração do OpenSSH para senha/forwarding. |

Também é possível configurar por variáveis de ambiente:

```bash
ADMIN_TOKEN="minha-senha-forte" APP_PORT=4000 sudo -E bash scripts/install-ubuntu.sh
```

## Como funciona o provisionamento SSH local

Na instalação padrão, o script:

1. instala `openssh-server`;
2. habilita autenticação por senha e `AllowTcpForwarding`;
3. instala o helper `/usr/local/sbin/4pluspainel-ssh-helper`;
4. cria uma regra sudoers permitindo que o serviço `www-data` execute **somente** esse helper;
5. o painel chama o helper para criar, bloquear, trocar senha, renovar e excluir usuários Linux.

O helper valida nomes de usuários e impede uso de contas reservadas como `root`, `ubuntu`, `www-data`, `sshd` etc.

## Comandos úteis na VPS

```bash
sudo systemctl status 4pluspainel
sudo journalctl -u 4pluspainel -f
sudo systemctl restart 4pluspainel
sudo nginx -t
sudo tail -f /var/log/auth.log
```

Ver o token admin:

```bash
sudo grep '^ADMIN_TOKEN=' /opt/4pluspainel/.env
```

Ver banco do painel:

```bash
sudo cat /var/lib/4pluspainel/db.json
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

## Desenvolvimento local

```bash
npm install
npm start
```

Abra: <http://localhost:3000>

No desenvolvimento local, se `ADMIN_TOKEN` não estiver configurado, use o token:

```text
admin
```

## Repositório

- GitHub: <https://github.com/Alefsousa5/4pluspainel->
- Branch Arena: `arena/01a039e9-4pluspainel`
