"""
測試 6: E2E 即時測試（透過公開或本機 URL）
涵蓋: 真實容器上的 API 端點 + 新欄位完整性

使用方式:
  pytest tests/test_e2e_live.py -m e2e -v
  CF_TEST_URL=https://cf-webgui.woowtech.io pytest tests/test_e2e_live.py -m e2e -v
"""

import os

import pytest
import httpx

pytestmark = [pytest.mark.e2e, pytest.mark.enable_socket]

BASE_URL = os.getenv("CF_TEST_URL", "http://localhost:8888")


@pytest.fixture()
def http():
    with httpx.Client(base_url=BASE_URL, timeout=15, follow_redirects=True) as c:
        yield c


def _get_csrf(http: httpx.Client) -> tuple[str, dict]:
    """取得 CSRF cookie 和 header。"""
    resp = http.get("/api/config")
    # Prefer fresh cookie from response; fall back to client cookie jar
    csrf_token = resp.cookies.get("csrftoken", "")
    if not csrf_token:
        # Server didn't set a new cookie — read from client jar
        for cookie in http.cookies.jar:
            if cookie.name == "csrftoken":
                csrf_token = cookie.value
                break
    return csrf_token, {"x-csrftoken": csrf_token}


# =========================================================================
# Health API
# =========================================================================
class TestE2EHealth:
    def test_health_ok(self, http):
        resp = http.get("/api/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["podman_connected"] is True
        assert data["tunnel_status"] in [
            "running", "stopped", "exited", "created", "not_found",
        ]


# =========================================================================
# Config API — GET
# =========================================================================
class TestE2EConfigGet:
    def test_get_config_has_all_fields(self, http):
        """GET /api/config 回傳所有 12 個欄位。"""
        resp = http.get("/api/config")
        assert resp.status_code == 200
        data = resp.json()
        required_fields = [
            "tunnel_token_secret", "tunnel_token_masked",
            "post_quantum", "log_level", "extra_args",
            "container_name", "container_image",
            "external_hostname", "additional_hosts",
            "tunnel_name", "catch_all_service", "nginx_proxy_manager",
        ]
        for f in required_fields:
            assert f in data, f"Missing: {f}"

    def test_get_config_token_masked(self, http):
        resp = http.get("/api/config")
        data = resp.json()
        assert "tunnel_token" not in data
        assert data["tunnel_token_masked"] is not None


# =========================================================================
# Config API — PUT 新欄位
# =========================================================================
class TestE2EConfigPut:
    def test_put_new_haos_fields(self, http):
        """PUT 所有 HAOS 新欄位，驗證回傳正確。"""
        csrf_token, csrf_headers = _get_csrf(http)
        payload = {
            "post_quantum": False,
            "log_level": "notice",
            "extra_args": "",
            "container_name": "cloudflared",
            "container_image": "cloudflare/cloudflared:latest",
            "external_hostname": "e2e-test.woowtech.io",
            "additional_hosts": [
                {
                    "hostname": "e2e-app.woowtech.io",
                    "service": "http://localhost:9999",
                    "disableChunkedEncoding": True,
                }
            ],
            "tunnel_name": "e2e-test-tunnel",
            "catch_all_service": "http://localhost:80",
            "nginx_proxy_manager": False,
        }
        resp = http.put("/api/config", json=payload, headers=csrf_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["external_hostname"] == "e2e-test.woowtech.io"
        assert data["tunnel_name"] == "e2e-test-tunnel"
        assert data["catch_all_service"] == "http://localhost:80"
        assert data["log_level"] == "notice"
        assert len(data["additional_hosts"]) == 1
        assert data["additional_hosts"][0]["disableChunkedEncoding"] is True

    def test_put_then_get_persistence(self, http):
        """PUT 後 GET 應回傳相同值。"""
        csrf_token, csrf_headers = _get_csrf(http)
        payload = {
            "external_hostname": "persist-e2e.woowtech.io",
            "tunnel_name": "persist-e2e",
            "nginx_proxy_manager": True,
            "container_image": "cloudflare/cloudflared:latest",
            "container_name": "cloudflared",
        }
        http.put("/api/config", json=payload, headers=csrf_headers)
        resp = http.get("/api/config")
        data = resp.json()
        assert data["external_hostname"] == "persist-e2e.woowtech.io"
        assert data["tunnel_name"] == "persist-e2e"
        assert data["nginx_proxy_manager"] is True

    def test_put_clear_additional_hosts(self, http):
        """清空 additional_hosts 應回傳空列表。"""
        csrf_token, csrf_headers = _get_csrf(http)
        # 先設定
        http.put(
            "/api/config",
            json={
                "additional_hosts": [
                    {"hostname": "x.io", "service": "http://localhost:1"}
                ],
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        # 再清空
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "additional_hosts": [],
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["additional_hosts"] == []


# =========================================================================
# Config API — PUT 所有 Log Level
# =========================================================================
class TestE2ELogLevels:
    @pytest.mark.parametrize(
        "level",
        ["trace", "debug", "info", "notice", "warn", "warning", "error", "fatal"],
    )
    def test_all_log_levels(self, http, level):
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "log_level": level,
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["log_level"] == level


# =========================================================================
# Config API — PUT 錯誤處理
# =========================================================================
class TestE2EConfigErrors:
    def test_invalid_image_rejected(self, http):
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "container_image": "nginx:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 400

    def test_shell_injection_rejected(self, http):
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "extra_args": "--flag; rm -rf /",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 422

    def test_empty_additional_host_hostname(self, http):
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "additional_hosts": [{"hostname": "", "service": "http://localhost:80"}],
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 422


# =========================================================================
# Tunnel Status API
# =========================================================================
class TestE2ETunnelStatus:
    def test_tunnel_status(self, http):
        resp = http.get("/api/tunnel/status")
        assert resp.status_code == 200
        data = resp.json()
        assert "status" in data
        assert "container_id" in data
        assert "uptime_seconds" in data


# =========================================================================
# OpenAPI Schema
# =========================================================================
class TestE2EOpenAPI:
    def test_openapi_has_additional_host_schema(self, http):
        resp = http.get("/openapi.json")
        assert resp.status_code == 200
        schemas = resp.json()["components"]["schemas"]
        assert "AdditionalHost" in schemas
        assert "hostname" in schemas["AdditionalHost"]["properties"]
        assert "service" in schemas["AdditionalHost"]["properties"]
        assert "disableChunkedEncoding" in schemas["AdditionalHost"]["properties"]

    def test_openapi_log_level_has_all_values(self, http):
        resp = http.get("/openapi.json")
        schemas = resp.json()["components"]["schemas"]
        levels = schemas["LogLevel"]["enum"]
        for expected in ["trace", "notice", "warning"]:
            assert expected in levels, f"Missing log level: {expected}"


# =========================================================================
# Cleanup: 還原預設值
# =========================================================================
class TestE2ECleanup:
    def test_restore_defaults(self, http):
        """測試結束後還原 config 為預設值。"""
        csrf_token, csrf_headers = _get_csrf(http)
        resp = http.put(
            "/api/config",
            json={
                "post_quantum": False,
                "log_level": "info",
                "extra_args": "",
                "container_name": "cloudflared",
                "container_image": "cloudflare/cloudflared:latest",
                "external_hostname": "",
                "additional_hosts": [],
                "tunnel_name": "",
                "catch_all_service": "",
                "nginx_proxy_manager": False,
            },
            headers=csrf_headers,
        )
        assert resp.status_code == 200
