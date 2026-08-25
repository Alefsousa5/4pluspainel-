# 4Plus Painel

Painel web para gerenciar **contas SSH** em VPS Debian/Ubuntu — criação, renovação,
limite de conexões simultâneas, bloqueio e sistema de revendas.

As contas são criadas de verdade no sistema operacional (`useradd`/`chpasswd`), com
data de expiração aplicada no próprio Linux.

---

## Instalação na VPS

> **Atenção:** enquanto o código estiver apenas na branch de trabalho
> (`arena/01a038fb-4pluspainel`) e não na `main`, use os comandos abaixo com
> `-b arena/01a038fb-4pluspainel`. Depois de fazer o merge na `main`, os
> comandos com `main` passam a funcionar normalmente.

Como **root**, em uma VPS Debian 11+ / Ubuntu 20.04+:

```bash
git clone -b arena/01a038fb-4pluspainel https://github.com/Alefsousa5/4pluspainel-.git
cd 4pluspainel-
sudo bash install.sh
```

Ou pelo instalador direto (ele procura sozinho a branch que contém o painel):

```bash
curl -sSLO https://raw.githubusercontent.com/Alefsousa5/4pluspainel-/arena/01a038fb-4pluspainel/install.sh
sudo bash install.sh
```

Se o repositório estiver em outra branch, é só informar:

```bash
sudo REPO_BRANCH=minha-branch bash install.sh
```

O instalador pergunta a **porta**, o **usuário admin** e a **senha**, depois:

1. instala `python3`, `git` e `openssh-server`;
2. copia o painel para `/opt/4pluspainel` (preservando o banco, se já existir);
3. cria o ambiente virtual e instala as dependências;
4. **ativa a autenticação por senha no SSH** — sem isso as contas do painel
   não conseguem conectar, e a maioria das VPS vem com ela desligada. A
   mudança é feita em `/etc/ssh/sshd_config.d/99-4pluspainel.conf`, com
   backup e validação (`sshd -t`) antes de recarregar o serviço;
5. registra o serviço systemd `4pluspainel` (inicia junto com o servidor);
6. instala o comando `painel`;
7. libera a porta no UFW, se estiver ativo.

Ao final ele mostra o endereço de acesso e as credenciais.

### Instalação silenciosa

```bash
sudo PANEL_UNATTENDED=1 PANEL_PORT=8080 PANEL_ADMIN=admin PANEL_ADMIN_PASS=suasenha bash install.sh
```

### Variáveis aceitas

| Variável | Para que serve |
|---|---|
| `PANEL_PORT` | porta do painel (padrão 8080) |
| `PANEL_ADMIN` / `PANEL_ADMIN_PASS` | credenciais do administrador |
| `PANEL_PUBLIC_HOST` | IP ou domínio que os clientes usam para conectar; se omitido, é detectado automaticamente |
| `REPO_BRANCH` | branch a ser baixada |
| `PANEL_UNATTENDED` | instala sem perguntar nada |

Se você usa um domínio, informe-o para que os dados copiados no painel já
saiam corretos:

```bash
sudo PANEL_PUBLIC_HOST=vpn.seudominio.com bash install.sh
```

---

### Se algo der errado

| Sintoma | Causa provável / solução |
|---|---|
| `install.sh: No such file or directory` | O clone veio da `main`, que ainda não tem o código. Use `git clone -b arena/01a038fb-4pluspainel ...` |
| `404: Not Found` ao usar `curl` | Mesma coisa: a URL apontava para a `main`. Use a URL com a branch correta acima. |
| `Execute como root` | Rode com `sudo bash install.sh`. |
| `A branch 'main' não contém o painel` | Normal — o instalador avisa e tenta a próxima branch sozinho. |
| Não abre no navegador | Libere a porta no firewall do provedor (Oracle/AWS/Contabo têm firewall próprio, fora do UFW). Confira com `painel status`. |
| Serviço não sobe | Veja o erro real com `painel logs` ou `journalctl -u 4pluspainel -n 50`. |
| Cliente não conecta no SSH (`Permission denied`) | Confirme que a senha está liberada: `sshd -T \| grep -i passwordauth` deve responder `yes`. O instalador ajusta isso, mas um painel de provedor pode sobrescrever. |
| Painel mostra host errado nos dados do cliente | Rode com `PANEL_PUBLIC_HOST=seu.ip.ou.dominio` ou edite `Environment=PANEL_PUBLIC_HOST=` em `/etc/systemd/system/4pluspainel.service` e rode `painel restart`. |

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
