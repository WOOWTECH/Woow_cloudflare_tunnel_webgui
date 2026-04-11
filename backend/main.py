import os
import re
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from starlette_csrf import CSRFMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

from .routers import config, tunnel, logs, health

app = FastAPI(
    title="Cloudflare Tunnel GUI",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url=None,
)

# ── Global Exception Handler ────────────────────────────
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={"detail": f"Internal server error: {type(exc).__name__}"},
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
    secret_path = Path("/app/config/.csrf_secret")
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
