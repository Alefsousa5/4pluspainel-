"""Integração com o sistema operacional: contas SSH reais.

Todas as chamadas usam listas de argumentos (sem shell=True) e os nomes de
usuário são validados antes de chegar aqui, evitando injeção de comandos.

Quando DEMO_MODE está ativo (painel rodando sem root), nada é executado no
sistema: as funções apenas simulam sucesso para permitir testes locais.
"""
from __future__ import annotations

import os
import pwd
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from datetime import datetime

from . import config
from .security import RESERVED_USERS, validate_username


class SSHError(RuntimeError):
    """Erro ao executar uma operação no sistema."""


@dataclass
class CommandResult:
    ok: bool
    output: str = ""
    demo: bool = False


def _run(cmd: list[str], input_text: str | None = None, timeout: int = 20) -> CommandResult:
    if config.DEMO_MODE:
        return CommandResult(True, f"[demo] {' '.join(cmd)}", demo=True)
    try:
        proc = subprocess.run(
            cmd,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise SSHError(f"Comando não encontrado: {cmd[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise SSHError(f"Tempo esgotado ao executar {cmd[0]}") from exc
    output = (proc.stdout or "") + (proc.stderr or "")
    return CommandResult(proc.returncode == 0, output.strip())


def _guard(username: str) -> None:
    error = validate_username(username)
    if error:
        raise SSHError(error)
    if username in RESERVED_USERS:
        raise SSHError(f"O usuário '{username}' é protegido.")


def system_user_exists(username: str) -> bool:
    if config.DEMO_MODE:
        return False
    try:
        pwd.getpwnam(username)
        return True
    except KeyError:
        return False


# --------------------------------------------------------------------------- #
# Operações de conta
# --------------------------------------------------------------------------- #
def create_user(username: str, password: str, expires: str, shell: str | None = None) -> CommandResult:
    """Cria a conta no sistema. `expires` no formato YYYY-MM-DD."""
    _guard(username)
    shell = shell or config.DEFAULT_SHELL
    if system_user_exists(username):
        raise SSHError(f"O usuário '{username}' já existe no sistema.")

    result = _run([
        "useradd",
        "-M",                  # sem diretório home
        "-s", shell,
        "-e", expires,         # data de expiração da conta
        username,
    ])
    if not result.ok:
        raise SSHError(f"Falha ao criar usuário: {result.output}")
    set_password(username, password)
    return result


def set_password(username: str, password: str) -> CommandResult:
    _guard(username)
    result = _run(["chpasswd"], input_text=f"{username}:{password}\n")
    if not result.ok:
        raise SSHError(f"Falha ao definir senha: {result.output}")
    return result


def set_expiry(username: str, expires: str) -> CommandResult:
    _guard(username)
    result = _run(["usermod", "-e", expires, username])
    if not result.ok:
        raise SSHError(f"Falha ao alterar validade: {result.output}")
    return result


def lock_user(username: str) -> CommandResult:
    _guard(username)
    result = _run(["usermod", "-L", username])
    if not result.ok:
        raise SSHError(f"Falha ao bloquear: {result.output}")
    kill_sessions(username)
    return result


def unlock_user(username: str) -> CommandResult:
    _guard(username)
    result = _run(["usermod", "-U", username])
    if not result.ok:
        raise SSHError(f"Falha ao desbloquear: {result.output}")
    return result


def delete_user(username: str) -> CommandResult:
    _guard(username)
    kill_sessions(username)
    if not system_user_exists(username) and not config.DEMO_MODE:
        return CommandResult(True, "usuário não existia no sistema")
    result = _run(["userdel", "-f", username])
    if not result.ok and "does not exist" not in result.output:
        raise SSHError(f"Falha ao remover usuário: {result.output}")
    return result


def kill_sessions(username: str) -> int:
    """Derruba todas as sessões/processos do usuário. Retorna quantos PIDs."""
    _guard(username)
    pids = list_pids(username)
    if config.DEMO_MODE or not pids:
        return len(pids)
    for pid in pids:
        try:
            os.kill(pid, 9)
        except (ProcessLookupError, PermissionError):
            continue
    return len(pids)


# --------------------------------------------------------------------------- #
# Conexões ativas
# --------------------------------------------------------------------------- #
# Processos que representam uma sessão de acesso remoto.
_SESSION_COMMS = {"sshd", "dropbear", "sshd-session"}


def _proc_comm(pid: str) -> str:
    try:
        with open(f"/proc/{pid}/comm") as fh:
            return fh.read().strip()
    except (OSError, ValueError):
        return ""


def _proc_start_time(pid: int) -> float:
    """Momento de início do processo (jiffies desde o boot). 0 se indisponível."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            data = fh.read()
        # o campo 22 (starttime) vem após o nome do comando, que pode ter espaços
        return float(data.rpartition(")")[2].split()[19])
    except (OSError, ValueError, IndexError):
        return 0.0


def _scan_sessions(uid_map: dict[int, str]) -> dict[str, list[int]]:
    """Varre /proc uma única vez e devolve as sessões SSH por usuário.

    Conta apenas processos de sessão (sshd/dropbear); processos comuns do
    usuário não inflam o número de conexões.
    """
    found: dict[str, list[int]] = {name: [] for name in uid_map.values()}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            uid = os.stat(f"/proc/{entry}").st_uid
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        name = uid_map.get(uid)
        if not name:
            continue
        if _proc_comm(entry) in _SESSION_COMMS:
            found[name].append(int(entry))
    return found


def _uid_map(usernames: list[str]) -> dict[int, str]:
    mapping: dict[int, str] = {}
    for name in usernames:
        try:
            mapping[pwd.getpwnam(name).pw_uid] = name
        except KeyError:
            continue
    return mapping


def list_pids(username: str) -> list[int]:
    """Todos os PIDs do usuário — usado ao derrubar/remover a conta."""
    if config.DEMO_MODE:
        return []
    try:
        uid = pwd.getpwnam(username).pw_uid
    except KeyError:
        return []
    pids: list[int] = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.stat(f"/proc/{entry}").st_uid == uid:
                pids.append(int(entry))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return pids


def list_sessions(username: str) -> list[int]:
    """PIDs das sessões SSH ativas do usuário, da mais antiga para a mais nova."""
    if config.DEMO_MODE:
        return []
    pids = _scan_sessions(_uid_map([username])).get(username, [])
    return sorted(pids, key=_proc_start_time)


def count_connections(username: str) -> int:
    """Número de sessões SSH abertas pelo usuário."""
    return len(list_sessions(username))


def connections_map(usernames: list[str]) -> dict[str, int]:
    """Contagem de conexões para vários usuários de uma vez (uma varredura)."""
    if config.DEMO_MODE:
        return {u: 0 for u in usernames}
    sessions = _scan_sessions(_uid_map(usernames))
    return {name: len(sessions.get(name, [])) for name in usernames}


def kill_excess_sessions(username: str, limit: int) -> int:
    """Encerra apenas as sessões que passam do limite.

    Mantém as `limit` conexões mais antigas (já estabelecidas) e derruba as
    mais recentes, para não desconectar o cliente por inteiro.
    """
    _guard(username)
    if limit < 1:
        return kill_sessions(username)
    sessions = list_sessions(username)
    excess = sessions[limit:]
    if config.DEMO_MODE or not excess:
        return len(excess)
    killed = 0
    for pid in excess:
        try:
            os.kill(pid, 9)
            killed += 1
        except (ProcessLookupError, PermissionError):
            continue
    return killed


# --------------------------------------------------------------------------- #
# Informações do servidor
# --------------------------------------------------------------------------- #
@dataclass
class ServerInfo:
    hostname: str = ""
    address: str = ""      # endereço que o cliente usa para conectar
    os_name: str = ""
    uptime: str = ""
    cpu_percent: float = 0.0
    mem_total_mb: int = 0
    mem_used_mb: int = 0
    disk_total_gb: float = 0.0
    disk_used_gb: float = 0.0
    ssh_ports: list[int] = field(default_factory=list)
    demo: bool = False

    @property
    def mem_percent(self) -> float:
        return round(self.mem_used_mb / self.mem_total_mb * 100, 1) if self.mem_total_mb else 0.0

    @property
    def disk_percent(self) -> float:
        return round(self.disk_used_gb / self.disk_total_gb * 100, 1) if self.disk_total_gb else 0.0


def _read_uptime() -> str:
    try:
        seconds = float(open("/proc/uptime").read().split()[0])
    except (OSError, ValueError):
        return "-"
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)


def _read_meminfo() -> tuple[int, int]:
    info: dict[str, int] = {}
    try:
        for line in open("/proc/meminfo"):
            key, _, rest = line.partition(":")
            info[key] = int(rest.strip().split()[0])
    except (OSError, ValueError, IndexError):
        return 0, 0
    total = info.get("MemTotal", 0) // 1024
    available = info.get("MemAvailable", info.get("MemFree", 0)) // 1024
    return total, max(total - available, 0)


def _read_cpu_percent() -> float:
    """Aproximação da carga usando loadavg (sem bloquear a requisição)."""
    try:
        load1 = os.getloadavg()[0]
        cores = os.cpu_count() or 1
        return round(min(load1 / cores * 100, 100.0), 1)
    except OSError:
        return 0.0


def _read_os_name() -> str:
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return os.uname().sysname


def _ports_from_file(path: str) -> set[int]:
    ports: set[int] = set()
    try:
        with open(path) as fh:
            for line in fh:
                match = re.match(r"\s*port\s+(\d+)", line, re.IGNORECASE)
                if match:
                    ports.add(int(match.group(1)))
    except OSError:
        pass
    return ports


def detect_ssh_ports() -> list[int]:
    """Portas SSH configuradas, incluindo as definidas em sshd_config.d/."""
    ports = _ports_from_file("/etc/ssh/sshd_config")
    # Distribuições modernas espalham a configuração em drop-ins.
    try:
        for name in sorted(os.listdir("/etc/ssh/sshd_config.d")):
            if name.endswith(".conf"):
                ports |= _ports_from_file(os.path.join("/etc/ssh/sshd_config.d", name))
    except OSError:
        pass
    if not ports:
        ports.add(22)
    return sorted(ports)


def public_address() -> str:
    """Endereço que o cliente deve usar para conectar.

    Prioriza PANEL_PUBLIC_HOST; senão descobre o IP público de saída. O
    hostname interno da máquina não serve para o cliente.
    """
    configured = os.environ.get("PANEL_PUBLIC_HOST", "").strip()
    if configured:
        return configured

    cached = getattr(public_address, "_cache", None)
    if cached:
        return cached

    import socket

    def _usable(value: str) -> bool:
        return bool(value) and not value.startswith("127.")

    address = ""
    # IP da interface usada para sair à internet (não abre conexão de fato).
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(1.0)
            sock.connect(("1.1.1.1", 80))
            candidate = sock.getsockname()[0]
        if _usable(candidate):
            address = candidate
    except OSError:
        pass

    # Fallback: primeiro endereço não-loopback resolvido pelo hostname.
    if not address:
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                candidate = info[4][0]
                if _usable(candidate):
                    address = candidate
                    break
        except OSError:
            pass

    address = address or os.uname().nodename
    public_address._cache = address  # type: ignore[attr-defined]
    return address


def server_info() -> ServerInfo:
    mem_total, mem_used = _read_meminfo()
    try:
        usage = shutil.disk_usage("/")
        disk_total = round(usage.total / 1024 ** 3, 1)
        disk_used = round((usage.total - usage.free) / 1024 ** 3, 1)
    except OSError:
        disk_total = disk_used = 0.0
    return ServerInfo(
        hostname=os.uname().nodename,
        address=public_address(),
        os_name=_read_os_name(),
        uptime=_read_uptime(),
        cpu_percent=_read_cpu_percent(),
        mem_total_mb=mem_total,
        mem_used_mb=mem_used,
        disk_total_gb=disk_total,
        disk_used_gb=disk_used,
        ssh_ports=detect_ssh_ports(),
        demo=config.DEMO_MODE,
    )


def parse_date(value: str) -> datetime | None:
    for fmt in ("%Y-%m-%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None
