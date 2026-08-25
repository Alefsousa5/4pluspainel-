"""4Plus Painel — gerenciador de contas SSH."""
from __future__ import annotations

import asyncio
import functools
import sqlite3
from typing import Any, Callable

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import auth, config, ssh_manager
from .database import init_db
from .services import (
    ServiceError,
    create_admin,
    create_ssh_user,
    dashboard_stats,
    delete_admin,
    delete_ssh_user,
    disconnect_user,
    enforce_rules,
    list_admins,
    list_users,
    recent_logs,
    renew_ssh_user,
    toggle_lock,
    update_admin,
    update_ssh_user,
)
from .security import random_password

app = FastAPI(title=config.APP_NAME, version=config.APP_VERSION, docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=config.BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(config.BASE_DIR / "templates"))
templates.env.globals["app_name"] = config.APP_NAME
templates.env.globals["app_version"] = config.APP_VERSION
templates.env.globals["demo_mode"] = config.DEMO_MODE


# --------------------------------------------------------------------------- #
# Dependências
# --------------------------------------------------------------------------- #
def current_user(request: Request) -> sqlite3.Row:
    admin = auth.read_session(request)
    if not admin:
        raise HTTPException(status_code=401, detail="Sessão expirada")
    return admin


def admin_only(user: sqlite3.Row = Depends(current_user)) -> sqlite3.Row:
    if user["role"] != "admin":
        raise HTTPException(status_code=403, detail="Apenas administradores")
    return user


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    wants_json = request.url.path.startswith("/api/") or "application/json" in (
        request.headers.get("accept") or ""
    )
    # 401 = sessão ausente/expirada -> manda para o login.
    # 403 = logado, mas sem permissão -> mostra o erro (redirecionar confundiria).
    if exc.status_code == 401 and not wants_json:
        return auth.login_redirect()
    if wants_json:
        return JSONResponse({"ok": False, "error": exc.detail}, status_code=exc.status_code)
    return templates.TemplateResponse(
        request, "error.html", {"code": exc.status_code, "message": exc.detail},
        status_code=exc.status_code,
    )


async def run_in_thread(func: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Executa uma função bloqueante numa thread.

    Equivale a asyncio.to_thread(), que só existe a partir do Python 3.9.
    O Ubuntu 20.04 ainda traz Python 3.8, então usamos run_in_executor.
    """
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, functools.partial(func, *args, **kwargs))


def api(handler: Callable[..., Any]):
    """Envolve handlers síncronos de API:

    - executa em thread separada (chamadas a useradd/chpasswd bloqueiam);
    - traduz ServiceError/SSHError em JSON 400 legível para o front.
    """
    @functools.wraps(handler)
    async def wrapper(*args, **kwargs):
        try:
            result = await run_in_thread(handler, *args, **kwargs)
            return JSONResponse({"ok": True, **(result or {})})
        except (ServiceError, ssh_manager.SSHError) as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        except Exception as exc:  # falha inesperada não deve vazar stacktrace
            return JSONResponse(
                {"ok": False, "error": f"Erro interno: {exc}"}, status_code=500
            )
    return wrapper


# --------------------------------------------------------------------------- #
# Ciclo de vida
# --------------------------------------------------------------------------- #
@app.on_event("startup")
async def startup() -> None:
    init_db()
    app.state.monitor = asyncio.create_task(monitor_loop())


@app.on_event("shutdown")
async def shutdown() -> None:
    task = getattr(app.state, "monitor", None)
    if task:
        task.cancel()


async def monitor_loop() -> None:
    """Aplica limites de conexão e expiração periodicamente."""
    while True:
        try:
            await asyncio.sleep(config.MONITOR_INTERVAL)
            await run_in_thread(enforce_rules)
        except asyncio.CancelledError:
            break
        except Exception:  # nunca derruba o loop
            continue


# --------------------------------------------------------------------------- #
# Login
# --------------------------------------------------------------------------- #
@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    if auth.read_session(request):
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(request, "login.html", {"error": None})


@app.post("/login", response_class=HTMLResponse)
async def login_submit(request: Request, username: str = Form(""), password: str = Form("")):
    admin = auth.authenticate(username, password)
    if not admin:
        return templates.TemplateResponse(
            request, "login.html", {"error": "Usuário ou senha inválidos."}, status_code=401
        )
    response = RedirectResponse("/", status_code=303)
    auth.set_session(response, admin["id"])
    return response


@app.get("/logout")
async def logout():
    response = RedirectResponse("/login", status_code=303)
    auth.clear_session(response)
    return response


# --------------------------------------------------------------------------- #
# Páginas
# --------------------------------------------------------------------------- #
@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, user: sqlite3.Row = Depends(current_user)):
    stats = dashboard_stats(user)
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "user": user,
            "stats": stats,
            "server": ssh_manager.server_info(),
            "logs": recent_logs(8, None if user["role"] == "admin" else user["username"]),
        },
    )


@app.get("/usuarios", response_class=HTMLResponse)
async def users_page(
    request: Request,
    q: str = "",
    status: str = "",
    user: sqlite3.Row = Depends(current_user),
):
    users = list_users(user, q.strip(), status.strip())
    return templates.TemplateResponse(
        request,
        "users.html",
        {
            "user": user,
            "users": users,
            "q": q,
            "status": status,
            "server": ssh_manager.server_info(),
            "suggested_password": random_password(),
        },
    )


@app.get("/revendas", response_class=HTMLResponse)
async def resellers_page(request: Request, user: sqlite3.Row = Depends(admin_only)):
    return templates.TemplateResponse(
        request, "resellers.html", {"user": user, "admins": list_admins()}
    )


@app.get("/logs", response_class=HTMLResponse)
async def logs_page(request: Request, user: sqlite3.Row = Depends(current_user)):
    return templates.TemplateResponse(
        request,
        "logs.html",
        {
            "user": user,
            "logs": recent_logs(200, None if user["role"] == "admin" else user["username"]),
        },
    )


# --------------------------------------------------------------------------- #
# API — contas SSH
# --------------------------------------------------------------------------- #
@app.get("/api/stats")
async def api_stats(user: sqlite3.Row = Depends(current_user)):
    stats = dashboard_stats(user)
    info = ssh_manager.server_info()
    return {
        "ok": True,
        "total": stats["total"],
        "online": stats["online"],
        "connections": stats["connections"],
        "expired": stats["expired"],
        "locked": stats["locked"],
        "expiring_soon": stats["expiring_soon"],
        "server": {
            "cpu": info.cpu_percent,
            "mem": info.mem_percent,
            "disk": info.disk_percent,
            "uptime": info.uptime,
        },
        "users": [
            {"id": u["id"], "username": u["username"], "online": u["online"],
             "status": u["status"], "days_left": u["days_left"]}
            for u in stats["users"]
        ],
    }


@app.post("/api/users")
@api
def api_create_user(
    username: str = Form(...),
    password: str = Form(...),
    connection_limit: int = Form(1),
    days: int = Form(30),
    note: str = Form(""),
    whatsapp: str = Form(""),
    user: sqlite3.Row = Depends(current_user),
):
    created = create_ssh_user(user, username, password, connection_limit, days, note, whatsapp)
    return {"user": created, "message": f"Conta {created['username']} criada."}


@app.post("/api/users/{user_id}")
@api
def api_update_user(
    user_id: int,
    password: str = Form(""),
    connection_limit: int = Form(1),
    days: int = Form(0),
    note: str = Form(""),
    whatsapp: str = Form(""),
    user: sqlite3.Row = Depends(current_user),
):
    update_ssh_user(user, user_id, password or None, connection_limit, days or None, note, whatsapp)
    return {"message": "Conta atualizada."}


@app.post("/api/users/{user_id}/renew")
@api
def api_renew_user(user_id: int, days: int = Form(30), user: sqlite3.Row = Depends(current_user)):
    expires = renew_ssh_user(user, user_id, days)
    return {"message": f"Renovado até {expires}.", "expires_at": expires}


@app.post("/api/users/{user_id}/lock")
@api
def api_lock_user(user_id: int, user: sqlite3.Row = Depends(current_user)):
    locked = toggle_lock(user, user_id)
    return {"locked": locked, "message": "Conta bloqueada." if locked else "Conta desbloqueada."}


@app.post("/api/users/{user_id}/kick")
@api
def api_kick_user(user_id: int, user: sqlite3.Row = Depends(current_user)):
    killed = disconnect_user(user, user_id)
    return {"message": f"{killed} sessão(ões) encerrada(s)."}


@app.post("/api/users/{user_id}/delete")
@api
def api_delete_user(user_id: int, user: sqlite3.Row = Depends(current_user)):
    username = delete_ssh_user(user, user_id)
    return {"message": f"Conta {username} removida."}


@app.get("/api/password")
async def api_password(_: sqlite3.Row = Depends(current_user)):
    return {"ok": True, "password": random_password()}


# --------------------------------------------------------------------------- #
# API — revendedores
# --------------------------------------------------------------------------- #
@app.post("/api/admins")
@api
def api_create_admin(
    username: str = Form(...),
    password: str = Form(...),
    role: str = Form("reseller"),
    user_limit: int = Form(0),
    user: sqlite3.Row = Depends(admin_only),
):
    create_admin(user["username"], username, password, role, user_limit)
    return {"message": f"Acesso {username} criado."}


@app.post("/api/admins/{admin_id}")
@api
def api_update_admin(
    admin_id: int,
    password: str = Form(""),
    user_limit: int = Form(0),
    active: str = Form("1"),
    user: sqlite3.Row = Depends(admin_only),
):
    update_admin(user["username"], admin_id, password or None, user_limit, active in ("1", "true", "on"))
    return {"message": "Acesso atualizado."}


@app.post("/api/admins/{admin_id}/delete")
@api
def api_delete_admin(admin_id: int, user: sqlite3.Row = Depends(admin_only)):
    if admin_id == user["id"]:
        raise ServiceError("Você não pode remover o próprio acesso.")
    delete_admin(user["username"], admin_id)
    return {"message": "Acesso removido."}


@app.get("/health")
async def health() -> Response:
    return JSONResponse({"ok": True, "version": config.APP_VERSION, "demo": config.DEMO_MODE})
