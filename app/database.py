"""Camada de acesso ao SQLite."""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta
from typing import Any, Iterator

from .config import DB_PATH
from .security import hash_password

SCHEMA = """
CREATE TABLE IF NOT EXISTS admins (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'reseller',  -- 'admin' ou 'reseller'
    user_limit    INTEGER NOT NULL DEFAULT 0,        -- 0 = ilimitado
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT NOT NULL,
    last_login    TEXT
);

CREATE TABLE IF NOT EXISTS ssh_users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password      TEXT NOT NULL,
    connection_limit INTEGER NOT NULL DEFAULT 1,
    expires_at    TEXT NOT NULL,
    owner_id      INTEGER NOT NULL,
    note          TEXT NOT NULL DEFAULT '',
    whatsapp      TEXT NOT NULL DEFAULT '',
    locked        INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    FOREIGN KEY (owner_id) REFERENCES admins (id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS logs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    actor      TEXT NOT NULL,
    action     TEXT NOT NULL,
    target     TEXT NOT NULL DEFAULT '',
    detail     TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_ssh_owner ON ssh_users (owner_id);
CREATE INDEX IF NOT EXISTS idx_logs_created ON logs (created_at DESC);
"""


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


@contextmanager
def db() -> Iterator[sqlite3.Connection]:
    conn = connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def query(sql: str, params: tuple = ()) -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute(sql, params).fetchall()


def query_one(sql: str, params: tuple = ()) -> sqlite3.Row | None:
    with db() as conn:
        return conn.execute(sql, params).fetchone()


def execute(sql: str, params: tuple = ()) -> int:
    with db() as conn:
        cur = conn.execute(sql, params)
        return cur.lastrowid or cur.rowcount


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def init_db(default_admin: str = "admin", default_password: str = "admin") -> dict[str, Any]:
    """Cria as tabelas e o administrador inicial (se ainda não existir)."""
    with db() as conn:
        conn.executescript(SCHEMA)
        row = conn.execute("SELECT COUNT(*) AS c FROM admins").fetchone()
        created = False
        if row["c"] == 0:
            conn.execute(
                "INSERT INTO admins (username, password_hash, role, user_limit, active, created_at)"
                " VALUES (?, ?, 'admin', 0, 1, ?)",
                (default_admin, hash_password(default_password), now()),
            )
            created = True
    return {"admin_created": created, "username": default_admin}


def add_log(actor: str, action: str, target: str = "", detail: str = "") -> None:
    execute(
        "INSERT INTO logs (created_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)",
        (now(), actor, action, target, detail),
    )


def days_from_now(days: int) -> str:
    return (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
