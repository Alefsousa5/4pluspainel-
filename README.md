# 4Plus Painel

Painel web para gerenciar **contas SSH** em VPS Debian/Ubuntu — criação, renovação,
limite de conexões simultâneas, bloqueio e sistema de revendas.

As contas são criadas de verdade no sistema operacional (`useradd`/`chpasswd`), com
data de expiração aplicada no próprio Linux.

---

## Instalação na VPS

Em uma VPS **Debian 11+ / Ubuntu 20.04+**, como **root**:

```bash
git clone -b arena/01a038fb-4pluspainel https://github.com/Alefsousa5/4pluspainel-.git
cd 4pluspainel-
sudo bash install.sh
```

> **Por que o `-b`?** O código ainda está na branch de trabalho — a `main` tem
> apenas o README. Depois que o [PR #1](https://github.com/Alefsousa5/4pluspainel-/pull/1)
> for aprovado, o clone simples (`git clone https://github.com/Alefsousa5/4pluspainel-.git`)
> passa a funcionar e o `-b` deixa de ser necessário.

Ao final ele mostra na tela:

```
   Acesse:  http://SEU_IP:8080
   Usuário: admin
   Senha:   ********
```

Esses dados também ficam salvos em `/opt/4pluspainel/acesso.txt` (só o root lê).
Se fechar o terminal, recupere com:

```bash
sudo painel acesso     # mostra IP, usuário e senha
sudo painel senha      # define uma nova senha
```

O instalador pergunta a **porta**, o **usuário admin** e a **senha** (quando
rodado num terminal; via pipe ele usa os padrões e gera uma senha aleatória),
depois:

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

O instalador grava tudo em **`/var/log/4pluspainel-install.log`** e, se falhar,
mostra o comando exato que quebrou. Para um diagnóstico completo:

```bash
sudo painel relatorio     # gera /tmp/4pluspainel-relatorio-*.txt
```

O relatório reúne versão do sistema e do Python, pacotes instalados, estado do
serviço, log do systemd, porta em escuta e configuração do SSH — com as senhas
mascaradas. É o arquivo mais útil para descobrir o que está errado.

| Sintoma | Causa provável / solução |
|---|---|
| `install.sh: No such file or directory` | O clone veio da `main`, que ainda não tem o código. Use `git clone -b arena/01a038fb-4pluspainel ...` |
| `404: Not Found` ao usar `curl` | Mesma coisa: a URL apontava para a `main`. Use a URL com a branch correta acima. |
| `Falha inesperada na linha 102` | Versão antiga: o script morria quando rodado sem terminal (`bash <(curl ...)`). Atualize e rode de novo — agora ele usa os valores padrão nesse caso. |
| `bash: /dev/fd/63: No such file or directory` | Acontece ao combinar `sudo` com `bash <(...)`. Rode como root (`sudo -i`) ou baixe o arquivo antes: `curl -sSLO <url> && sudo bash install.sh`. |
| Painel abre e o login funciona, mas criar conta dá "Erro interno" | Versão antiga rodando em Python 3.8 (Ubuntu 20.04): o código usava `asyncio.to_thread`, que só existe no 3.9+. Atualize (`git pull`) e reinstale. |
| Instalou sem perguntar nada | É esperado quando não há terminal (pipe, cron, `bash <(curl ...)`). Para escolher porta e senha, baixe o arquivo antes: `curl -sSLO <url> && sudo bash install.sh`. |
| `Execute como root` | Rode com `sudo bash install.sh`. |
| `A branch 'main' não contém o painel` | Normal — o instalador avisa e tenta a próxima branch sozinho. |
| Não abre no navegador | Libere a porta no firewall do provedor (Oracle/AWS/Contabo têm firewall próprio, fora do UFW). Confira com `painel status`. |
| Serviço não sobe | Rode `sudo painel doctor`: ele aponta a causa (porta ocupada, módulo faltando etc.). O log completo fica em `painel logs`. |
| Serviço fica reiniciando sem parar | `painel doctor` mostra o motivo. O serviço não desiste: assim que a causa for resolvida, ele volta sozinho. |
| `ensurepip is not available` | Falta o pacote venv do Python. O instalador tenta resolver sozinho; se não conseguir: `apt install -y python3-venv` (ou `python3.8-venv`, conforme a versão). |
| `Falha ao instalar as dependências Python` | Geralmente é falta de acesso ao pypi.org. O instalador agora mostra o erro real do pip. Para recriar o ambiente: `sudo painel reparar`. |
| Painel parou depois de uma atualização | `sudo painel doctor` aponta o que quebrou e `sudo painel reparar` refaz o ambiente Python. |
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
| `painel doctor` | diagnostica a instalação (Python, dependências, banco, serviço) |
| `painel reparar` | recria o ambiente Python quando as dependências quebram |
| `painel relatorio` | gera um relatório completo para diagnóstico (sem senhas) |
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

## O serviço systemd

O painel roda como o serviço `4pluspainel`, iniciado automaticamente no boot:

- espera a rede estar pronta (`network-online.target`) antes de abrir a porta;
- reinicia sozinho se cair, **sem limite de tentativas** — se a porta estiver
  ocupada ou a rede demorar após um reboot, ele continua tentando até subir;
- para de forma limpa com `SIGINT`, deixando o uvicorn finalizar as
  requisições em andamento (parada em menos de 1s, sem risco para o banco).

```bash
sudo systemctl status 4pluspainel     # ou: painel status
sudo journalctl -u 4pluspainel -f     # ou: painel logs
```

## Compatibilidade

Requer **Python 3.8 ou superior**. O `requirements.txt` usa faixas de versão
em vez de versões fixas, então o pip escolhe o que funciona no Python da sua
VPS — de **Python 3.8** (Ubuntu 20.04) a 3.12 (Ubuntu 24.04).

O instalador verifica a versão do Python antes de começar e aborta com uma
mensagem clara se for antiga demais. O código é validado contra o Python 3.8
para não usar recursos que só existem em versões mais novas.

## Desenvolvimento local

Sem root o painel entra em **modo demonstração**: a interface funciona normalmente,
mas nenhuma conta é criada no sistema operacional.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --reload --port 8080
```

Acesse http://localhost:8080 — usuário `admin`, senha `admin`.
