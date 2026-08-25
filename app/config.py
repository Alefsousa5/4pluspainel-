"""Configuração central do 4Plus Painel."""
from __future__ import annotations

import os
import secrets
from pathlib import Path


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "sim"}


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


APP_NAME = os.environ.get("PANEL_NAME", "4Plus Painel")
APP_VERSION = "1.0.0"

BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent

# Diretório de dados (banco, chave de sessão). Em produção: /opt/4pluspainel/data
DATA_DIR = Path(os.environ.get("PANEL_DATA_DIR", ROOT_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = Path(os.environ.get("PANEL_DB", DATA_DIR / "painel.db"))
SECRET_FILE = DATA_DIR / "secret.key"

HOST = os.environ.get("PANEL_HOST", "0.0.0.0")
PORT = _env_int("PANEL_PORT", 8080)

# Intervalo (segundos) do daemon que checa limites e validade
MONITOR_INTERVAL = _env_int("PANEL_MONITOR_INTERVAL", 20)

# Shell padrão das contas SSH criadas (contas de túnel não precisam de shell real)
DEFAULT_SHELL = os.environ.get("PANEL_DEFAULT_SHELL", "/bin/false")

SESSION_HOURS = _env_int("PANEL_SESSION_HOURS", 12)

# Modo demonstração: não toca no sistema operacional, só no banco.
# Ativado automaticamente quando o painel não roda como root.
DEMO_MODE = _env_bool("PANEL_DEMO", not hasattr(os, "geteuid") or os.geteuid() != 0)


def get_secret_key() -> str:
    """Chave de assinatura dos cookies de sessão, persistida em disco."""
    env_key = os.environ.get("PANEL_SECRET")
    if env_key:
        return env_key
    if SECRET_FILE.exists():
        value = SECRET_FILE.read_text(encoding="utf-8").strip()
        if value:
            return value
    value = secrets.token_urlsafe(48)
    SECRET_FILE.write_text(value, encoding="utf-8")
    try:
        SECRET_FILE.chmod(0o600)
    except OSError:
        pass
    return value


SECRET_KEY = get_secret_key()
