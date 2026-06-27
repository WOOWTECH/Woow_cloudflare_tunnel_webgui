"""
E2E 即時測試(對真實運行中的容器)。

使用方式:
  CF_TEST_URL=http://localhost:8888 pytest -m e2e -v

預設 deselect(僅在有運行容器時手動跑)。對齊新「本地管理 + 單一容器」設計,
不依賴 podman、不使用舊 HA 欄位。
"""

import os

import pytest
import httpx

pytestmark = [pytest.mark.e2e]

BASE_URL = os.getenv("CF_TEST_URL", "http://localhost:8888")


@pytest.fixture()
def http():
    with httpx.Client(base_url=BASE_URL, timeout=15, follow_redirects=True) as c:
        yield c


def _get_csrf(http: httpx.Client) -> dict:
    """取得 CSRF cookie 並回傳對應 header。"""
    resp = http.get("/api/config")
    csrf_token = resp.cookies.get("csrftoken", "")
    if not csrf_token:
        for cookie in http.cookies.jar:
            if cookie.name == "csrftoken":
                csrf_token = cookie.value
                break
    return {"x-csrftoken": csrf_token}


# =========================================================================
# Health
# =========================================================================
class TestE2EHealth:
    def test_health_ok(self, http):
        resp = http.get("/api/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert isinstance(data["process_running"], bool)


# =========================================================================
# Setup state
# =========================================================================
class TestE2ESetupState:
    def test_setup_state_shape(self, http):
        resp = http.get("/api/setup/state")
        assert resp.status_code == 200
        data = resp.json()
        assert "has_cert" in data
        assert "has_tunnel" in data
        assert data["mode"] in ("local", "token")


# =========================================================================
# Config GET — 新欄位
# =========================================================================
class TestE2EConfigGet:
    def test_get_config_has_new_fields(self, http):
        resp = http.get("/api/config")
        assert resp.status_code == 200
        data = resp.json()
        for f in [
            "mode", "tunnel_name", "routes", "catch_all_service",
            "post_quantum", "log_level", "run_parameters",
            "no_tls_verify", "tunnel_token_masked",
        ]:
            assert f in data, f"Missing: {f}"

    def test_get_config_token_not_leaked(self, http):
        data = http.get("/api/config").json()
        assert "tunnel_token" not in data
        assert data["tunnel_token_masked"] is not None


# =========================================================================
# Config PUT — 新欄位與持久化
# =========================================================================
class TestE2EConfigPut:
    def test_put_routes_and_persist(self, http):
        headers = _get_csrf(http)
        payload = {
            "mode": "local",
            "tunnel_name": "e2e-tunnel",
            "log_level": "notice",
            "catch_all_service": "http://localhost:80",
            "routes": [
                {"hostname": "e2e-app.example.com",
                 "service": "http://localhost:9999",
                 "disableChunkedEncoding": True},
            ],
        }
        resp = http.put("/api/config", json=payload, headers=headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["tunnel_name"] == "e2e-tunnel"
        assert data["log_level"] == "notice"
        assert len(data["routes"]) == 1
        # 持久化
        again = http.get("/api/config").json()
        assert again["tunnel_name"] == "e2e-tunnel"
        assert len(again["routes"]) == 1


# =========================================================================
# Config PUT — 驗證錯誤
# =========================================================================
class TestE2EConfigErrors:
    def test_invalid_log_level_rejected(self, http):
        headers = _get_csrf(http)
        resp = http.put("/api/config", json={"log_level": "bogus"}, headers=headers)
        assert resp.status_code == 422

    def test_invalid_route_hostname_rejected(self, http):
        headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={"routes": [{"hostname": "https://x.com", "service": "http://l:1"}]},
            headers=headers,
        )
        assert resp.status_code == 422


# =========================================================================
# Tunnel status
# =========================================================================
class TestE2ETunnelStatus:
    def test_tunnel_status_shape(self, http):
        resp = http.get("/api/tunnel/status")
        assert resp.status_code == 200
        assert isinstance(resp.json()["running"], bool)


# =========================================================================
# OpenAPI
# =========================================================================
class TestE2EOpenAPI:
    def test_openapi_has_route_schema(self, http):
        resp = http.get("/openapi.json")
        assert resp.status_code == 200
        schemas = resp.json()["components"]["schemas"]
        assert "Route" in schemas
        props = schemas["Route"]["properties"]
        assert "hostname" in props and "service" in props


# =========================================================================
# Cleanup
# =========================================================================
class TestE2ECleanup:
    def test_restore_defaults(self, http):
        headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "mode": "local", "tunnel_name": "", "routes": [],
                "catch_all_service": "", "post_quantum": False,
                "log_level": "info", "run_parameters": "", "no_tls_verify": True,
            },
            headers=headers,
        )
        assert resp.status_code == 200
