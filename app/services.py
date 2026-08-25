"""Regras de negócio: contas SSH, revendedores e sincronização com o sistema."""
from __future__ import annotations

import sqlite3
from datetime import datetime
from typing import Any

from . import ssh_manager
from .database import add_log, days_from_now, execute, now, query, query_one
from .security import hash_password, validate_password, validate_username


class ServiceError(Exception):
    """Erro de validação/negócio exibido ao usuário."""


# --------------------------------------------------------------------------- #
# Administradores / revendedores
# --------------------------------------------------------------------------- #
def get_admin(admin_id: int) -> sqlite3.Row | None:
    return query_one("SELECT * FROM admins WHERE id = ?", (admin_id,))


def get_admin_by_username(username: str) -> sqlite3.Row | None:
    return query_one("SELECT * FROM admins WHERE username = ?", (username,))


def list_admins() -> list[dict[str, Any]]:
    rows = query(
        """
        SELECT a.*, (SELECT COUNT(*) FROM ssh_users u WHERE u.owner_id = a.id) AS total_users
        FROM admins a ORDER BY a.role DESC, a.username
        """
    )
    return [dict(r) for r in rows]


def create_admin(actor: str, username: str, password: str, role: str, user_limit: int) -> int:
    username = (username or "").strip().lower()
    error = validate_username(username) or validate_password(password)
    if error:
        raise ServiceError(error)
    if role not in {"admin", "reseller"}:
        raise ServiceError("Perfil inválido.")
    if get_admin_by_username(username):
        raise ServiceError(f"Já existe um acesso chamado '{username}'.")
    admin_id = execute(
        "INSERT INTO admins (username, password_hash, role, user_limit, active, created_at)"
        " VALUES (?, ?, ?, ?, 1, ?)",
        (username, hash_password(password), role, max(user_limit, 0), now()),
    )
    add_log(actor, "criou acesso", username, f"perfil={role} limite={user_limit or 'ilimitado'}")
    return admin_id


def update_admin(actor: str, admin_id: int, password: str | None, user_limit: int, active: bool) -> None:
    admin = get_admin(admin_id)
    if not admin:
        raise ServiceError("Acesso não encontrado.")
    if password:
        error = validate_password(password)
        if error:
            raise ServiceError(error)
        execute("UPDATE admins SET password_hash = ? WHERE id = ?", (hash_password(password), admin_id))
    execute(
        "UPDATE admins SET user_limit = ?, active = ? WHERE id = ?",
        (max(user_limit, 0), 1 if active else 0, admin_id),
    )
    add_log(actor, "editou acesso", admin["username"], f"limite={user_limit or 'ilimitado'} ativo={active}")


def delete_admin(actor: str, admin_id: int) -> None:
    admin = get_admin(admin_id)
    if not admin:
        raise ServiceError("Acesso não encontrado.")
    if admin["role"] == "admin":
        remaining = query_one("SELECT COUNT(*) AS c FROM admins WHERE role = 'admin'")
        if remaining and remaining["c"] <= 1:
            raise ServiceError("Não é possível remover o último administrador.")
    # remove também as contas SSH pertencentes a ele
    for row in query("SELECT username FROM ssh_users WHERE owner_id = ?", (admin_id,)):
        try:
            ssh_manager.delete_user(row["username"])
        except ssh_manager.SSHError:
            pass
    execute("DELETE FROM ssh_users WHERE owner_id = ?", (admin_id,))
    execute("DELETE FROM admins WHERE id = ?", (admin_id,))
    add_log(actor, "removeu acesso", admin["username"])


# --------------------------------------------------------------------------- #
# Contas SSH
# --------------------------------------------------------------------------- #
def _row_to_user(row: sqlite3.Row, online: int = 0) -> dict[str, Any]:
    data = dict(row)
    expires = ssh_manager.parse_date(data["expires_at"])
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    days_left = (expires - today).days if expires else 0
    data["days_left"] = days_left
    data["expired"] = days_left < 0
    data["online"] = online
    data["over_limit"] = online > data["connection_limit"]
    if data["locked"]:
        data["status"] = "bloqueado"
    elif data["expired"]:
        data["status"] = "expirado"
    elif online > 0:
        data["status"] = "online"
    else:
        data["status"] = "ativo"
    return data


def list_users(viewer: sqlite3.Row, search: str = "", status: str = "") -> list[dict[str, Any]]:
    sql = """
        SELECT u.*, a.username AS owner_name
        FROM ssh_users u JOIN admins a ON a.id = u.owner_id
    """
    clauses: list[str] = []
    params: list[Any] = []
    if viewer["role"] != "admin":
        clauses.append("u.owner_id = ?")
        params.append(viewer["id"])
    if search:
        clauses.append("(u.username LIKE ? OR u.note LIKE ? OR u.whatsapp LIKE ?)")
        like = f"%{search}%"
        params += [like, like, like]
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)
    sql += " ORDER BY u.username"

    rows = query(sql, tuple(params))
    counts = ssh_manager.connections_map([r["username"] for r in rows])
    users = [_row_to_user(r, counts.get(r["username"], 0)) for r in rows]
    if status:
        users = [u for u in users if u["status"] == status]
    return users


def get_user(user_id: int) -> sqlite3.Row | None:
    return query_one("SELECT * FROM ssh_users WHERE id = ?", (user_id,))


def _assert_can_manage(viewer: sqlite3.Row, user: sqlite3.Row) -> None:
    if viewer["role"] != "admin" and user["owner_id"] != viewer["id"]:
        raise ServiceError("Você não tem permissão sobre esta conta.")


def _check_quota(viewer: sqlite3.Row) -> None:
    limit = viewer["user_limit"] or 0
    if limit <= 0:
        return
    row = query_one("SELECT COUNT(*) AS c FROM ssh_users WHERE owner_id = ?", (viewer["id"],))
    if row and row["c"] >= limit:
        raise ServiceError(f"Limite de {limit} contas atingido para este acesso.")


def create_ssh_user(
    viewer: sqlite3.Row,
    username: str,
    password: str,
    connection_limit: int,
    days: int,
    note: str = "",
    whatsapp: str = "",
) -> dict[str, Any]:
    username = (username or "").strip().lower()
    error = validate_username(username) or validate_password(password)
    if error:
        raise ServiceError(error)
    if connection_limit < 1 or connection_limit > 999:
        raise ServiceError("O limite de conexões deve estar entre 1 e 999.")
    if days < 1 or days > 3650:
        raise ServiceError("A validade deve estar entre 1 e 3650 dias.")
    if query_one("SELECT id FROM ssh_users WHERE username = ?", (username,)):
        raise ServiceError(f"A conta '{username}' já existe no painel.")
    if ssh_manager.system_user_exists(username):
        raise ServiceError(f"O usuário '{username}' já existe no sistema operacional.")
    _check_quota(viewer)

    expires = days_from_now(days)
    ssh_manager.create_user(username, password, expires)
    user_id = execute(
        """
        INSERT INTO ssh_users
            (username, password, connection_limit, expires_at, owner_id, note, whatsapp, locked, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        """,
        (username, password, connection_limit, expires, viewer["id"], note.strip()[:120],
         whatsapp.strip()[:32], now(), now()),
    )
    add_log(viewer["username"], "criou conta SSH", username,
            f"limite={connection_limit} validade={expires}")
    return {"id": user_id, "username": username, "password": password, "expires_at": expires}


def update_ssh_user(
    viewer: sqlite3.Row,
    user_id: int,
    password: str | None,
    connection_limit: int,
    days: int | None,
    note: str,
    whatsapp: str,
) -> None:
    user = get_user(user_id)
    if not user:
        raise ServiceError("Conta não encontrada.")
    _assert_can_manage(viewer, user)
    if connection_limit < 1 or connection_limit > 999:
        raise ServiceError("O limite de conexões deve estar entre 1 e 999.")

    expires = user["expires_at"]
    if days:
        if days < 1 or days > 3650:
            raise ServiceError("A validade deve estar entre 1 e 3650 dias.")
        expires = days_from_now(days)
        ssh_manager.set_expiry(user["username"], expires)

    if password:
        error = validate_password(password)
        if error:
            raise ServiceError(error)
        ssh_manager.set_password(user["username"], password)
    else:
        password = user["password"]

    execute(
        """UPDATE ssh_users SET password = ?, connection_limit = ?, expires_at = ?,
           note = ?, whatsapp = ?, updated_at = ? WHERE id = ?""",
        (password, connection_limit, expires, note.strip()[:120], whatsapp.strip()[:32], now(), user_id),
    )
    add_log(viewer["username"], "editou conta SSH", user["username"],
            f"limite={connection_limit} validade={expires}")


def renew_ssh_user(viewer: sqlite3.Row, user_id: int, days: int) -> str:
    user = get_user(user_id)
    if not user:
        raise ServiceError("Conta não encontrada.")
    _assert_can_manage(viewer, user)
    if days < 1 or days > 3650:
        raise ServiceError("Informe de 1 a 3650 dias.")

    base = ssh_manager.parse_date(user["expires_at"]) or datetime.now()
    if base < datetime.now():
        base = datetime.now()
    from datetime import timedelta
    expires = (base + timedelta(days=days)).strftime("%Y-%m-%d")

    ssh_manager.set_expiry(user["username"], expires)
    if user["locked"]:
        ssh_manager.unlock_user(user["username"])
    execute(
        "UPDATE ssh_users SET expires_at = ?, locked = 0, updated_at = ? WHERE id = ?",
        (expires, now(), user_id),
    )
    add_log(viewer["username"], "renovou conta SSH", user["username"], f"+{days} dias -> {expires}")
    return expires


def toggle_lock(viewer: sqlite3.Row, user_id: int) -> bool:
    user = get_user(user_id)
    if not user:
        raise ServiceError("Conta não encontrada.")
    _assert_can_manage(viewer, user)
    new_state = not bool(user["locked"])
    if new_state:
        ssh_manager.lock_user(user["username"])
    else:
        ssh_manager.unlock_user(user["username"])
    execute("UPDATE ssh_users SET locked = ?, updated_at = ? WHERE id = ?",
            (1 if new_state else 0, now(), user_id))
    add_log(viewer["username"], "bloqueou conta" if new_state else "desbloqueou conta", user["username"])
    return new_state


def delete_ssh_user(viewer: sqlite3.Row, user_id: int) -> str:
    user = get_user(user_id)
    if not user:
        raise ServiceError("Conta não encontrada.")
    _assert_can_manage(viewer, user)
    ssh_manager.delete_user(user["username"])
    execute("DELETE FROM ssh_users WHERE id = ?", (user_id,))
    add_log(viewer["username"], "removeu conta SSH", user["username"])
    return user["username"]


def disconnect_user(viewer: sqlite3.Row, user_id: int) -> int:
    user = get_user(user_id)
    if not user:
        raise ServiceError("Conta não encontrada.")
    _assert_can_manage(viewer, user)
    killed = ssh_manager.kill_sessions(user["username"])
    add_log(viewer["username"], "derrubou sessões", user["username"], f"{killed} processos")
    return killed


# --------------------------------------------------------------------------- #
# Painel / estatísticas
# --------------------------------------------------------------------------- #
def dashboard_stats(viewer: sqlite3.Row) -> dict[str, Any]:
    users = list_users(viewer)
    online = sum(1 for u in users if u["online"] > 0)
    return {
        "total": len(users),
        "online": online,
        "connections": sum(u["online"] for u in users),
        "expired": sum(1 for u in users if u["expired"]),
        "locked": sum(1 for u in users if u["locked"]),
        "expiring_soon": sum(1 for u in users if 0 <= u["days_left"] <= 3),
        "users": users,
    }


def recent_logs(limit: int = 60, actor: str | None = None) -> list[dict[str, Any]]:
    if actor:
        rows = query(
            "SELECT * FROM logs WHERE actor = ? ORDER BY id DESC LIMIT ?", (actor, limit)
        )
    else:
        rows = query("SELECT * FROM logs ORDER BY id DESC LIMIT ?", (limit,))
    return [dict(r) for r in rows]


def enforce_rules() -> dict[str, int]:
    """Aplica limite de conexões e expiração. Executado pelo monitor."""
    rows = query("SELECT * FROM ssh_users")
    if not rows:
        return {"expired": 0, "over_limit": 0}
    counts = ssh_manager.connections_map([r["username"] for r in rows])
    expired = over_limit = 0
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)

    for row in rows:
        exp = ssh_manager.parse_date(row["expires_at"])
        if exp and exp < today and not row["locked"]:
            try:
                ssh_manager.lock_user(row["username"])
                execute("UPDATE ssh_users SET locked = 1, updated_at = ? WHERE id = ?", (now(), row["id"]))
                add_log("sistema", "conta expirada bloqueada", row["username"])
                expired += 1
            except ssh_manager.SSHError:
                pass
            continue

        online = counts.get(row["username"], 0)
        if online > row["connection_limit"]:
            try:
                killed = ssh_manager.kill_sessions(row["username"])
                add_log("sistema", "excesso de conexões", row["username"],
                        f"{online}/{row['connection_limit']} — {killed} sessões encerradas")
                over_limit += 1
            except ssh_manager.SSHError:
                pass
    return {"expired": expired, "over_limit": over_limit}
