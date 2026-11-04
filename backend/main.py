import os
import re
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from starlette_csrf import CSRFMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

from . import __version__
from .routers import config, tunnel, logs, health, setup, paas
from .services import runtime
from .services.process_manager import autostart_args, effective_metrics_addr

logger = logging.getLogger(__name__)
DATA_DIR = Path("/data")

# Everything this process creates on /data (token, cert.pem, tunnel.json,
# PaaS link state, CSRF secret) is private from the moment it exists.
os.umask(0o077)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # On startup: auto-resume the tunnel if already configured (reboot parity),
    # unless an operator stopped it, or a credential file cannot be made private.
    try:
        runtime.check_credentials(DATA_DIR)
        if runtime.stopped_by_operator(DATA_DIR):
            raise RuntimeError("stopped by the operator (/data/.tunnel_stopped)")
        cfg = await tunnel.config_mgr.load()
        args = autostart_args(
            cfg,
            token=tunnel.token_store.get(),
            cert_exists=(DATA_DIR / "cert.pem").exists(),
            tunnel_exists=(DATA_DIR / "tunnel.json").exists(),
            config_exists=(DATA_DIR / "config.json").exists(),
            token_file=str(tunnel.token_store.path),
            metrics=effective_metrics_addr(),
        )
        if args and not tunnel.pm.is_running():
            logger.info("Autostarting cloudflared (mode=%s)", cfg.get("mode"))
            await tunnel.pm.start(args)
    except Exception as exc:  # never block app startup on autostart failure
        logger.warning("Tunnel autostart skipped: %s", exc)
    await paas.reconcile_pending_disconnect()
    yield
    # On shutdown: stop the cloudflared child process cleanly.
    try:
        await tunnel.pm.stop()
    except Exception:
        pass


app = FastAPI(
    title="Cloudflare Tunnel GUI",
    version=__version__,
    docs_url="/api/docs",
    redoc_url=None,
    lifespan=lifespan,
)

# ── Global Exception Handler ────────────────────────────
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={"detail": f"Internal server error: {type(exc).__name__}"},
    )

@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    # FastAPI's default 422 echoes the submitted value (for PUT /api/config,
    # possibly the tunnel token). Keep where and why, drop the input.
    return JSONResponse(
        status_code=422,
        content={"detail": [
            {"loc": list(error["loc"]), "type": error["type"], "msg": error["msg"]}
            for error in exc.errors()
        ]},
    )

# ── CSRF Protection (Double Submit Cookie) ───────────────
# Wrap CSRFMiddleware to skip WebSocket connections (starlette-csrf
# only handles HTTP scope and crashes on WebSocket scope).
class WebSocketSafeCSRFMiddleware:
    """Wraps CSRFMiddleware, bypassing it for WebSocket connections."""

    def __init__(self, app: ASGIApp, **kwargs):
        self._csrf = CSRFMiddleware(app, **kwargs)
        self._app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] == "websocket":
            await self._app(scope, receive, send)
        else:
            await self._csrf(scope, receive, send)


def _get_csrf_secret() -> str:
    """Return a stable CSRF secret: env var > persisted file > generate & persist."""
    env = os.getenv("CSRF_SECRET")
    if env:
        return env
    secret_path = Path("/data/.csrf_secret")
    if secret_path.exists():
        return secret_path.read_text().strip()
    secret = os.urandom(32).hex()
    secret_path.parent.mkdir(parents=True, exist_ok=True)
    secret_path.write_text(secret)
    return secret


CSRF_SECRET = _get_csrf_secret()
app.add_middleware(
    WebSocketSafeCSRFMiddleware,
    secret=CSRF_SECRET,
    cookie_name="csrftoken",
    header_name="x-csrftoken",
    exempt_urls=[
        re.compile(r"^/api/docs"),
        re.compile(r"^/api/health"),
        re.compile(r"^/openapi\.json"),
    ],
)

# ── CORS ─────────────────────────────────────────────────
ALLOWED_ORIGINS = (
    os.getenv("CORS_ORIGINS", "").split(",")
    if os.getenv("CORS_ORIGINS")
    else []
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "PUT", "POST"],
    allow_headers=["*"],
)

# ── Routers ──────────────────────────────────────────────
app.include_router(config.router)
app.include_router(tunnel.router)
app.include_router(logs.router)
app.include_router(health.router)
app.include_router(setup.router)
app.include_router(paas.router)

# ── Static Files + SPA Fallback ─────────────────────────
STATIC_DIR = Path("/app/static")
if STATIC_DIR.exists():
    # Mount /assets for hashed JS/CSS bundles
    assets_dir = STATIC_DIR / "assets"
    if assets_dir.exists():
        app.mount("/assets", StaticFiles(directory=str(assets_dir)), name="assets")

    # Serve specific static files
    @app.get("/favicon.svg", include_in_schema=False)
    async def favicon():
        return FileResponse(STATIC_DIR / "favicon.svg")

    # SPA catch-all: any non-API, non-asset path serves index.html
    @app.get("/{full_path:path}", include_in_schema=False)
    async def spa_fallback(full_path: str):
        return FileResponse(STATIC_DIR / "index.html")
