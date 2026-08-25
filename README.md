# 4Plus Painel

Painel web para gerenciar **contas SSH** em VPS Debian/Ubuntu — criação, renovação,
limite de conexões simultâneas, bloqueio e sistema de revendas.

As contas são criadas de verdade no sistema operacional (`useradd`/`chpasswd`), com
data de expiração aplicada no próprio Linux.

---

## Instalação na VPS

Como **root**, em uma VPS Debian 11+ / Ubuntu 20.04+:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/main/install.sh)
```

Ou clonando o repositório:

```bash
git clone https://github.com/Alefsousa5/4pluspainel-.git
cd 4pluspainel-
sudo bash install.sh
```

O instalador pergunta a **porta**, o **usuário admin** e a **senha**, depois:

1. instala `python3`, `git` e `openssh-server`;
2. copia o painel para `/opt/4pluspainel`;
3. cria o ambiente virtual e instala as dependências;
4. registra o serviço systemd `4pluspainel` (inicia junto com o servidor);
5. instala o comando `painel`;
6. libera a porta no UFW, se estiver ativo.

Ao final ele mostra o endereço de acesso e as credenciais.

### Instalação silenciosa

```bash
sudo PANEL_UNATTENDED=1 PANEL_PORT=8080 PANEL_ADMIN=admin PANEL_ADMIN_PASS=suasenha bash install.sh
```

---

## Comando `painel`

| Comando | O que faz |
|---|---|
| `painel` | resumo: estado do serviço e endereço de acesso |
| `painel status` | situação detalhada do serviço |
| `painel start` / `stop` / `restart` | controla o serviço |
| `painel logs` | acompanha o log em tempo real |
| `painel porta 9000` | troca a porta do painel |
| `painel senha` | redefine a senha de um administrador |
| `painel backup` | salva o banco em `/root/4pluspainel-backup-*.tar.gz` |
| `painel atualizar` | atualiza via git e reinicia |
| `painel desinstalar` | remove o painel (contas SSH do sistema são preservadas) |

---

## Funcionalidades

**Contas SSH**
- criação com usuário, senha, limite de conexões e validade em dias
- gerador de senha aleatória e botão para copiar os dados de acesso do cliente
- renovação somando dias à validade atual
- bloqueio/desbloqueio e encerramento das sessões ativas
- exclusão removendo a conta do sistema operacional
- busca por usuário, nota ou WhatsApp e filtro por status

**Controle automático** (daemon interno, a cada 20s)
- derruba sessões que excedem o limite de conexões simultâneas
- bloqueia contas vencidas

**Revendas**
- perfis `administrador` e `revendedor`
- cada revendedor só enxerga e gerencia as próprias contas
- limite de contas por revendedor (0 = ilimitado)
- ativar/desativar acesso

**Painel**
- totais de contas, online, vencendo e expiradas
- CPU, memória, disco, uptime e portas SSH detectadas
- registro de todas as ações realizadas

---

## Estrutura

```
app/
  main.py          rotas web e API
  services.py      regras de negócio
  ssh_manager.py   integração com o sistema (useradd, chpasswd, sessões)
  database.py      SQLite
  security.py      hash de senha e validações
  auth.py          sessão por cookie assinado
  templates/       páginas
  static/          CSS e JS
install.sh         instalador para VPS
painel             utilitário de linha de comando
```

Dados ficam em `/opt/4pluspainel/data/painel.db`.

---

## Observações de segurança

- Senhas do painel são guardadas com **PBKDF2-SHA256** (180 mil iterações).
- Nomes de usuário são validados por regex e comandos são executados **sem shell**,
  o que impede injeção de comandos.
- Nomes de sistema (`root`, `www-data`, etc.) são bloqueados.
- As senhas das contas SSH ficam salvas em texto no banco — é necessário para
  reexibi-las ao revendedor. Mantenha o acesso ao servidor restrito.
- O painel roda como root (precisa disso para gerenciar usuários do sistema).
  Recomenda-se colocá-lo atrás de um proxy com HTTPS se for exposto à internet.

## Desenvolvimento local

Sem root o painel entra em **modo demonstração**: a interface funciona normalmente,
mas nenhuma conta é criada no sistema operacional.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --reload --port 8080
```

Acesse http://localhost:8080 — usuário `admin`, senha `admin`.
