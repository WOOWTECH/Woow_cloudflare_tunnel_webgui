"""
Shared fixtures for the Cloudflare Tunnel Web GUI test suite (本地管理版).

Two test modes:
  1. Unit / integration: pytest with httpx TestClient (mocked CloudflaredCLI / ProcessManager)
  2. E2E live:          pytest -m e2e against the running container
"""

import os
import sys
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import ASGITransport, AsyncClient

# ---------------------------------------------------------------------------
# Make backend importable from repo root
# ---------------------------------------------------------------------------
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

# Set CSRF_SECRET before importing backend.main (avoids /app/config write)
os.environ.setdefault("CSRF_SECRET", "test-csrf-secret-for-pytest")

# Pre-import router modules so patch.object works
from backend.routers import config as config_router  # noqa: E402
from backend.routers import health as health_router  # noqa: E402
from backend.routers import tunnel as tunnel_router  # noqa: E402
from backend.routers import setup as setup_router  # noqa: E402
from backend.routers import paas as paas_router  # noqa: E402
from backend.routers import logs as logs_router  # noqa: E402
from backend.services import metrics as metrics_service  # noqa: E402
from backend.models.schemas import TunnelStatus  # noqa: E402


def make_token(account: str = "acct", tunnel: str = "tun", secret: str = "c2VjcmV0") -> str:
    """A syntactically valid, synthetic Cloudflare tunnel token (base64 JSON
    with a/t/s), so normalize_tunnel_token accepts it. Not a real credential."""
    import base64
    import json as _json
    raw = _json.dumps({"a": account, "t": tunnel, "s": secret}).encode()
    return base64.b64encode(raw).decode().rstrip("=")


@pytest.fixture()
def tunnel_status():
    """What the mocked cloudflared /ready reports; tests may mutate it."""
    return TunnelStatus(status="stopped", metrics_reachable=False)


# ---------------------------------------------------------------------------
# Fixtures: temp config dir
# ---------------------------------------------------------------------------
@pytest.fixture()
def tmp_config_dir(tmp_path):
    """Provide a temp directory that acts as /app/config or /data."""
    return tmp_path


@pytest.fixture()
def settings_file(tmp_config_dir):
    """Return path to a temp settings.json (does not exist yet)."""
    return tmp_config_dir / "settings.json"


# ---------------------------------------------------------------------------
# Fixtures: mock CloudflaredCLI / ProcessManager replacements
# ---------------------------------------------------------------------------
@pytest.fixture()
def mock_cli():
    cli = MagicMock()

    async def _login(src_cert, dest_cert):
        yield "https://dash.cloudflare.com/argotunnel?aud=test"

    cli.login = _login
    cli.create_tunnel = AsyncMock(return_value="uuid-test")
    cli.route_dns = AsyncMock(return_value=None)
    cli.ingress_validate = AsyncMock(return_value=(True, "OK"))
    return cli


@pytest.fixture()
def mock_pm():
    pm = MagicMock()
    pm.is_running.return_value = True
    pm.start = AsyncMock(return_value=None)
    pm.stop = AsyncMock(return_value=None)
    pm.restart = AsyncMock(return_value=None)
    pm.recent_logs.return_value = ["log line 1"]
    return pm


# ---------------------------------------------------------------------------
# Fixtures: FastAPI TestClient with mocked dependencies
# ---------------------------------------------------------------------------
@pytest.fixture()
async def client(tmp_config_dir, mock_cli, mock_pm, tunnel_status):
    """
    Async httpx client wired to the real FastAPI app with:
      - ConfigManager writing to tmp dir (not /app/config)
      - TokenStore writing to tmp dir (not /data)
      - CloudflaredCLI / ProcessManager mocked
      - CSRF disabled via exempt patterns
    """
    from backend.services.config_manager import ConfigManager
    from backend.services.token_store import TokenStore

    test_cfg_mgr = ConfigManager(config_path=tmp_config_dir / "settings.json")
    test_token_store = TokenStore(path=tmp_config_dir / ".tunnel_token")

    async def _status():
        return tunnel_status

    with ExitStack() as stack:
        stack.enter_context(patch.dict(os.environ, {"PAAS_LINK_STATE": str(tmp_config_dir / "paas-link.json")}))
        stack.enter_context(patch.object(metrics_service, "tunnel_status", _status))
        stack.enter_context(patch.object(config_router, "pm", mock_pm))
        stack.enter_context(patch.object(config_router, "cli", mock_cli))
        stack.enter_context(patch.object(config_router, "DATA_DIR", tmp_config_dir))
        stack.enter_context(patch.object(tunnel_router, "cli", mock_cli))
        stack.enter_context(patch.object(tunnel_router, "DATA_DIR", tmp_config_dir))
        stack.enter_context(patch.object(health_router, "DATA_DIR", tmp_config_dir))
        stack.enter_context(patch.object(setup_router, "token_store", test_token_store))
        stack.enter_context(patch.object(paas_router, "config_mgr", test_cfg_mgr))
        stack.enter_context(patch.object(paas_router, "token_store", test_token_store))
        stack.enter_context(patch.object(paas_router, "pm", mock_pm))
        stack.enter_context(patch.object(paas_router, "cli", mock_cli))
        stack.enter_context(patch.object(paas_router, "DATA_DIR", tmp_config_dir))
        stack.enter_context(patch.object(config_router, "config_mgr", test_cfg_mgr))
        stack.enter_context(patch.object(config_router, "token_store", test_token_store))
        stack.enter_context(patch.object(tunnel_router, "config_mgr", test_cfg_mgr))
        stack.enter_context(patch.object(tunnel_router, "pm", mock_pm))
        stack.enter_context(patch.object(tunnel_router, "token_store", test_token_store))
        stack.enter_context(patch.object(health_router, "pm", mock_pm))
        stack.enter_context(patch.object(logs_router, "pm", mock_pm))
        stack.enter_context(patch.object(setup_router, "config_mgr", test_cfg_mgr))
        stack.enter_context(patch.object(setup_router, "cli", mock_cli))
        stack.enter_context(patch.object(setup_router, "pm", mock_pm))
        from backend.main import app

        transport = ASGITransport(app=app)
        async with AsyncClient(
            transport=transport,
            base_url="http://testserver",
        ) as ac:
            # Warm up: GET /api/health (CSRF-exempt) to grab the cookie
            warmup = await ac.get("/api/health")
            csrf_token = warmup.cookies.get("csrftoken", "")
            if csrf_token:
                ac.headers["x-csrftoken"] = csrf_token
                ac.cookies.set("csrftoken", csrf_token)
            yield ac


# ---------------------------------------------------------------------------
# Fixtures: live E2E base URL
# ---------------------------------------------------------------------------
@pytest.fixture()
def live_base_url():
    return os.getenv("CF_TEST_URL", "http://127.0.0.1:18000")
