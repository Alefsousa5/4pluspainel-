"""Hash de senhas e utilidades de sessão (sem dependências externas)."""
from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets

_ITERATIONS = 180_000
_ALGO = "pbkdf2_sha256"


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _ITERATIONS)
    return "{}${}${}${}".format(
        _ALGO,
        _ITERATIONS,
        base64.b64encode(salt).decode(),
        base64.b64encode(digest).decode(),
    )


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iterations, salt_b64, digest_b64 = stored.split("$")
        if algo != _ALGO:
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(digest_b64)
        candidate = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, int(iterations))
        return hmac.compare_digest(candidate, expected)
    except (ValueError, TypeError):
        return False


USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{2,31}$")

# Nomes que jamais podem ser criados/removidos pelo painel
RESERVED_USERS = {
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail",
    "news", "uucp", "proxy", "www-data", "backup", "list", "irc", "gnats",
    "nobody", "systemd-network", "systemd-resolve", "messagebus", "sshd",
    "ubuntu", "debian", "admin", "user", "4pluspainel",
}


def validate_username(username: str) -> str | None:
    """Retorna mensagem de erro ou None se o nome for válido."""
    username = (username or "").strip()
    if not USERNAME_RE.match(username):
        return (
            "Usuário inválido: use 3 a 32 caracteres, começando por letra minúscula, "
            "apenas letras minúsculas, números, hífen e underline."
        )
    if username in RESERVED_USERS:
        return f"O nome '{username}' é reservado pelo sistema."
    return None


def validate_password(password: str) -> str | None:
    if not password or len(password) < 4:
        return "A senha precisa ter pelo menos 4 caracteres."
    if len(password) > 64:
        return "A senha pode ter no máximo 64 caracteres."
    if any(c in password for c in "\n\r\t:'\"\\`$"):
        return "A senha contém caracteres não permitidos."
    return None


def random_password(size: int = 8) -> str:
    alphabet = "abcdefghijkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(size))
