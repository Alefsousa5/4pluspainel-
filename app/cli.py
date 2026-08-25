"""Ponte entre o menu de terminal e as regras de negócio do painel.

Reaproveita exatamente as mesmas funções usadas pela interface web, para que
uma conta criada pelo menu seja idêntica a uma criada pelo navegador.

Uso: python -m app.cli <comando> [argumentos...]
Saída: texto simples, pensado para ser lido por humanos no terminal.
"""
from __future__ import annotations

import sys

from . import ssh_manager
from .database import init_db, query_one
from .security import random_password
from .services import (
    ServiceError,
    create_ssh_user,
    delete_ssh_user,
    disconnect_user,
    list_users,
    renew_ssh_user,
    toggle_lock,
    dashboard_stats,
)

# Cores ANSI (as mesmas do script painel)
G = "\033[1;32m"; R = "\033[1;31m"; Y = "\033[1;33m"; B = "\033[1;36m"
BOLD = "\033[1m"; NC = "\033[0m"


def _admin():
    """Administrador usado pelo menu (quem roda no terminal já é root)."""
    row = query_one("SELECT * FROM admins WHERE role = 'admin' AND active = 1 ORDER BY id LIMIT 1")
    if not row:
        print(f"{R}Nenhum administrador ativo encontrado.{NC}")
        sys.exit(1)
    return row


def _fmt_status(u: dict) -> str:
    cor = {"online": G, "ativo": B, "expirado": R, "bloqueado": R}.get(u["status"], "")
    return f"{cor}{u['status']:<10}{NC}"


def cmd_listar() -> None:
    users = list_users(_admin())
    if not users:
        print(f"{Y}Nenhuma conta SSH cadastrada.{NC}")
        return
    print()
    print(f"{BOLD}{'#':<4}{'USUÁRIO':<18}{'SENHA':<16}{'CONEX.':<9}{'VALIDADE':<13}{'STATUS'}{NC}")
    print("─" * 74)
    for i, u in enumerate(users, 1):
        conex = f"{u['online']}/{u['connection_limit']}"
        dias = f"{u['expires_at']} ({u['days_left']}d)"
        print(f"{i:<4}{u['username']:<18}{u['password']:<16}{conex:<9}{dias:<13}{_fmt_status(u)}")
    print("─" * 74)
    print(f"Total: {len(users)} conta(s)\n")


def cmd_criar(argv: list[str]) -> None:
    username, password, limite, dias = argv[0], argv[1], int(argv[2]), int(argv[3])
    nota = argv[4] if len(argv) > 4 else ""
    info = create_ssh_user(_admin(), username, password, limite, dias, nota)
    srv = ssh_manager.server_info()
    print()
    print(f"{G}✓ Conta criada com sucesso!{NC}")
    print("─" * 42)
    print(f"  {BOLD}Usuário :{NC} {info['username']}")
    print(f"  {BOLD}Senha   :{NC} {info['password']}")
    print(f"  {BOLD}Host    :{NC} {srv.address}")
    print(f"  {BOLD}Porta   :{NC} {', '.join(str(p) for p in srv.ssh_ports)}")
    print(f"  {BOLD}Validade:{NC} {info['expires_at']} ({dias} dias)")
    print(f"  {BOLD}Conexões:{NC} {limite}")
    print("─" * 42)
    print()


def _pick(indice: int) -> dict:
    users = list_users(_admin())
    if indice < 1 or indice > len(users):
        raise ServiceError(f"Número inválido: escolha de 1 a {len(users)}.")
    return users[indice - 1]


def cmd_remover(argv: list[str]) -> None:
    u = _pick(int(argv[0]))
    nome = delete_ssh_user(_admin(), u["id"])
    print(f"{G}✓ Conta '{nome}' removida do painel e do sistema.{NC}")


def cmd_renovar(argv: list[str]) -> None:
    u = _pick(int(argv[0]))
    exp = renew_ssh_user(_admin(), u["id"], int(argv[1]))
    print(f"{G}✓ Conta '{u['username']}' renovada até {exp}.{NC}")


def cmd_bloquear(argv: list[str]) -> None:
    u = _pick(int(argv[0]))
    bloqueada = toggle_lock(_admin(), u["id"])
    estado = "bloqueada" if bloqueada else "desbloqueada"
    print(f"{G}✓ Conta '{u['username']}' {estado}.{NC}")


def cmd_derrubar(argv: list[str]) -> None:
    u = _pick(int(argv[0]))
    n = disconnect_user(_admin(), u["id"])
    print(f"{G}✓ {n} sessão(ões) de '{u['username']}' encerrada(s).{NC}")


def cmd_online() -> None:
    users = [u for u in list_users(_admin()) if u["online"] > 0]
    if not users:
        print(f"{Y}Nenhuma conta conectada no momento.{NC}")
        return
    print()
    print(f"{BOLD}{'USUÁRIO':<18}{'CONEXÕES':<12}{'LIMITE'}{NC}")
    print("─" * 42)
    for u in users:
        excedeu = R if u["over_limit"] else G
        print(f"{u['username']:<18}{excedeu}{u['online']:<12}{NC}{u['connection_limit']}")
    print("─" * 42 + "\n")


def cmd_resumo() -> None:
    s = dashboard_stats(_admin())
    srv = ssh_manager.server_info()
    print()
    print(f"  {BOLD}Contas:{NC} {s['total']}   "
          f"{G}Online:{NC} {s['online']}   "
          f"{Y}Vencendo:{NC} {s['expiring_soon']}   "
          f"{R}Expiradas:{NC} {s['expired']}")
    print(f"  {BOLD}Servidor:{NC} CPU {srv.cpu_percent}%  "
          f"RAM {srv.mem_percent}%  Disco {srv.disk_percent}%  Uptime {srv.uptime}")
    print(f"  {BOLD}SSH:{NC} {srv.address} porta {', '.join(str(p) for p in srv.ssh_ports)}")
    print()


def cmd_senha() -> None:
    print(random_password())


def main() -> None:
    init_db()
    if len(sys.argv) < 2:
        print("uso: python -m app.cli <comando>")
        sys.exit(1)
    cmd, argv = sys.argv[1], sys.argv[2:]
    acoes = {
        "listar": lambda: cmd_listar(),
        "criar": lambda: cmd_criar(argv),
        "remover": lambda: cmd_remover(argv),
        "renovar": lambda: cmd_renovar(argv),
        "bloquear": lambda: cmd_bloquear(argv),
        "derrubar": lambda: cmd_derrubar(argv),
        "online": lambda: cmd_online(),
        "resumo": lambda: cmd_resumo(),
        "gerar-senha": lambda: cmd_senha(),
    }
    if cmd not in acoes:
        print(f"comando desconhecido: {cmd}")
        sys.exit(1)
    try:
        acoes[cmd]()
    except (ServiceError, ssh_manager.SSHError) as exc:
        print(f"{R}✗ {exc}{NC}")
        sys.exit(1)


if __name__ == "__main__":
    main()
