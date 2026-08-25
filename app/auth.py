"""Autenticação via cookie de sessão assinado."""
from __future__ import annotations

import sqlite3
import time

from fastapi import Request
from fastapi.responses import RedirectResponse
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from .config import SECRET_KEY, SESSION_HOURS
from .database import execute, now
from .security import verify_password
from .services import get_admin, get_admin_by_username

COOKIE_NAME = "4plus_session"
_serializer = URLSafeTimedSerializer(SECRET_KEY, salt="4pluspainel-session")


def create_session_cookie(admin_id: int) -> str:
    return _serializer.dumps({"id": admin_id, "ts": int(time.time())})


def read_session(request: Request) -> sqlite3.Row | None:
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return None
    try:
        data = _serializer.loads(token, max_age=SESSION_HOURS * 3600)
    except (BadSignature, SignatureExpired):
        return None
    admin = get_admin(int(data.get("id", 0)))
    if not admin or not admin["active"]:
        return None
    return admin


def authenticate(username: str, password: str) -> sqlite3.Row | None:
    admin = get_admin_by_username((username or "").strip().lower())
    if not admin or not admin["active"]:
        return None
    if not verify_password(password or "", admin["password_hash"]):
        return None
    execute("UPDATE admins SET last_login = ? WHERE id = ?", (now(), admin["id"]))
    return admin


def set_session(response, admin_id: int) -> None:
    response.set_cookie(
        COOKIE_NAME,
        create_session_cookie(admin_id),
        max_age=SESSION_HOURS * 3600,
        httponly=True,
        samesite="lax",
        path="/",
    )


def clear_session(response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")


def login_redirect() -> RedirectResponse:
    return RedirectResponse("/login", status_code=303)
