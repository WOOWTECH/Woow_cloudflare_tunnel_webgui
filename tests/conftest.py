"""
Shared fixtures for the Cloudflare Tunnel Web GUI test suite.

Two test modes:
  1. Unit / integration: pytest with httpx TestClient (mocked Podman)
  2. E2E live:          pytest -m e2e against the running container
"""

import os
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from httpx import ASGITransport, AsyncClient

# ---------------------------------------------------------------------------
# Make backend importable from repo root
# ---------------------------------------------------------------------------
import sys

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

# Set CSRF_SECRET before importing backend.main (avoids /app/config write)
os.environ.setdefault("CSRF_SECRET", "test-csrf-secret-for-pytest")

# Pre-import router modules so patch.object works
from backend.routers import config as config_router  # noqa: E402
from backend.routers import health as health_router  # noqa: E402
from backend.routers import tunnel as tunnel_router  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures: temp config dir & ConfigManager override
# ---------------------------------------------------------------------------
@pytest.fixture()
def tmp_config_dir(tmp_path):
    """Provide a temp directory that acts as /app/config."""
    return tmp_path


@pytest.fixture()
def settings_file(tmp_config_dir):
    """Return path to a temp settings.json (does not exist yet)."""
    return tmp_config_dir / "settings.json"


# ---------------------------------------------------------------------------
# Fixtures: mock PodmanManager so tests don't need a real socket
#
# DEPRECATED (待 Phase 6 移除): Podman 相關 fixtures(mock_podman 及其在
# client fixture 中的使用)會在 Phase 6 去 Podman 化時一併移除。目前暫時
# 保留以免既有測試 import 爆掉;不要在新測試中依賴它們。
# ---------------------------------------------------------------------------
@pytest.fixture()
def mock_podman():
    mgr = MagicMock()
    mgr.secret_get_masked.return_value = "****mask****"
    mgr.secret_set.return_value = None
    mgr.ping.return_value = True
    mgr.secret_exists.return_value = True
    mgr.get_status.return_value = {
        "status": "running",
        "container_id": "abc123",
        "image": "cloudflare/cloudflared:latest",
        "started_at": "2026-01-01T00:00:00Z",
        "uptime_seconds": 3600,
        "restart_count": 0,
        "exit_code": 0,
    }
    mgr.start_container.return_value = "abc123"
    mgr.stop_container.return_value = True
    mgr.restart_container.return_value = True
    return mgr


# ---------------------------------------------------------------------------
# Fixtures: FastAPI TestClient with mocked dependencies
# ---------------------------------------------------------------------------
@pytest.fixture()
async def client(tmp_config_dir, mock_podman):
    """
    Async httpx client wired to the real FastAPI app with:
      - ConfigManager writing to tmp dir (not /app/config)
      - PodmanManager mocked
      - CSRF disabled via exempt patterns
    """
    from backend.services.config_manager import ConfigManager

    test_cfg_mgr = ConfigManager(config_path=tmp_config_dir / "settings.json")

    with (
        patch.object(config_router, "config_mgr", test_cfg_mgr),
        patch.object(config_router, "podman_mgr", mock_podman),
        patch.object(health_router, "config_mgr", test_cfg_mgr),
        patch.object(health_router, "podman_mgr", mock_podman),
        patch.object(tunnel_router, "config_mgr", test_cfg_mgr),
        patch.object(tunnel_router, "podman_mgr", mock_podman),
    ):
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
# Workaround: pytest-homeassistant-custom-component unconditionally calls
# pytest_socket.disable_socket() in its own pytest_runtest_setup hook,
# overriding the enable_socket marker.  Re-enable sockets for e2e tests.
# ---------------------------------------------------------------------------
@pytest.fixture(autouse=True)
def _allow_socket_for_e2e(request):
    """Re-enable real sockets for tests marked with @pytest.mark.enable_socket."""
    marker = request.node.get_closest_marker("enable_socket")
    if marker is not None:
        import pytest_socket
        pytest_socket.enable_socket()
        yield
        pytest_socket.disable_socket(allow_unix_socket=True)
    else:
        yield


# ---------------------------------------------------------------------------
# Fixtures: live E2E base URL
# ---------------------------------------------------------------------------
@pytest.fixture()
def live_base_url():
    return os.getenv("CF_TEST_URL", "http://localhost:8888")
