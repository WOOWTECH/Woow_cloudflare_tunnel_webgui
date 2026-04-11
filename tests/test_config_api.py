"""
測試 3: Config API 端點整合測試
涵蓋: GET/PUT + 新欄位 + 邊緣條件 + 錯誤處理
"""

import pytest


# =========================================================================
# GET /api/config
# =========================================================================
class TestConfigGet:
    @pytest.mark.asyncio
    async def test_get_returns_all_fields(self, client):
        """GET 應回傳所有 HAOS 新欄位。"""
        resp = await client.get("/api/config")
        assert resp.status_code == 200
        data = resp.json()
        for key in [
            "tunnel_token_secret",
            "tunnel_token_masked",
            "post_quantum",
            "log_level",
            "extra_args",
            "container_name",
            "container_image",
            "external_hostname",
            "additional_hosts",
            "tunnel_name",
            "catch_all_service",
            "nginx_proxy_manager",
        ]:
            assert key in data, f"Missing field: {key}"

    @pytest.mark.asyncio
    async def test_get_default_values(self, client):
        """首次 GET 應回傳所有預設值。"""
        resp = await client.get("/api/config")
        data = resp.json()
        assert data["post_quantum"] is False
        assert data["log_level"] == "info"
        assert data["external_hostname"] == ""
        assert data["additional_hosts"] == []
        assert data["tunnel_name"] == ""
        assert data["catch_all_service"] == ""
        assert data["nginx_proxy_manager"] is False

    @pytest.mark.asyncio
    async def test_get_masks_token(self, client):
        """GET 回傳的 token 應被遮蔽。"""
        resp = await client.get("/api/config")
        data = resp.json()
        assert "tunnel_token" not in data  # raw token 不應出現
        assert "tunnel_token_masked" in data


# =========================================================================
# PUT /api/config — 新欄位
# =========================================================================
class TestConfigPutNewFields:
    @pytest.mark.asyncio
    async def test_put_external_hostname(self, client):
        """PUT 應能設定 external_hostname。"""
        resp = await client.put(
            "/api/config",
            json={
                "external_hostname": "home.test.io",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["external_hostname"] == "home.test.io"

    @pytest.mark.asyncio
    async def test_put_tunnel_name(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "tunnel_name": "my-test-tunnel",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["tunnel_name"] == "my-test-tunnel"

    @pytest.mark.asyncio
    async def test_put_catch_all_service(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "catch_all_service": "http://localhost:80",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["catch_all_service"] == "http://localhost:80"

    @pytest.mark.asyncio
    async def test_put_nginx_proxy_manager(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "nginx_proxy_manager": True,
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["nginx_proxy_manager"] is True

    @pytest.mark.asyncio
    async def test_put_additional_hosts(self, client):
        """PUT 應能設定 additional_hosts 列表。"""
        hosts = [
            {"hostname": "app.test.io", "service": "http://localhost:3000"},
            {
                "hostname": "api.test.io",
                "service": "http://localhost:4000",
                "disableChunkedEncoding": True,
            },
        ]
        resp = await client.put(
            "/api/config",
            json={
                "additional_hosts": hosts,
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["additional_hosts"]) == 2
        assert data["additional_hosts"][0]["hostname"] == "app.test.io"
        assert data["additional_hosts"][1]["disableChunkedEncoding"] is True


# =========================================================================
# PUT /api/config — 所有新欄位一次設定
# =========================================================================
class TestConfigPutAllNewFields:
    @pytest.mark.asyncio
    async def test_put_all_new_fields_together(self, client):
        """一次設定所有 HAOS 新欄位，驗證完整性。"""
        payload = {
            "post_quantum": True,
            "log_level": "trace",
            "extra_args": "--protocol quic",
            "container_name": "cloudflared",
            "container_image": "cloudflare/cloudflared:latest",
            "external_hostname": "home.example.com",
            "additional_hosts": [
                {"hostname": "a.io", "service": "http://localhost:3000"},
                {
                    "hostname": "b.io",
                    "service": "http://localhost:4000",
                    "disableChunkedEncoding": True,
                },
            ],
            "tunnel_name": "woowtech-tunnel",
            "catch_all_service": "http://localhost:80",
            "nginx_proxy_manager": False,
        }
        resp = await client.put("/api/config", json=payload)
        assert resp.status_code == 200
        data = resp.json()

        assert data["post_quantum"] is True
        assert data["log_level"] == "trace"
        assert data["external_hostname"] == "home.example.com"
        assert len(data["additional_hosts"]) == 2
        assert data["tunnel_name"] == "woowtech-tunnel"
        assert data["catch_all_service"] == "http://localhost:80"
        assert data["nginx_proxy_manager"] is False

    @pytest.mark.asyncio
    async def test_put_then_get_consistency(self, client):
        """PUT 後 GET 應回傳相同值（持久化驗證）。"""
        payload = {
            "external_hostname": "persist.test.io",
            "tunnel_name": "persist-tunnel",
            "nginx_proxy_manager": True,
            "container_image": "cloudflare/cloudflared:latest",
            "container_name": "cloudflared",
        }
        await client.put("/api/config", json=payload)
        resp = await client.get("/api/config")
        data = resp.json()
        assert data["external_hostname"] == "persist.test.io"
        assert data["tunnel_name"] == "persist-tunnel"
        assert data["nginx_proxy_manager"] is True


# =========================================================================
# PUT /api/config — 新增 Log Level
# =========================================================================
class TestConfigPutLogLevels:
    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "level", ["trace", "debug", "info", "notice", "warn", "warning", "error", "fatal"]
    )
    async def test_all_log_levels_accepted(self, client, level):
        resp = await client.put(
            "/api/config",
            json={
                "log_level": level,
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["log_level"] == level

    @pytest.mark.asyncio
    async def test_invalid_log_level_rejected(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "log_level": "verbose",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 422


# =========================================================================
# PUT /api/config — 錯誤處理 & 邊緣條件
# =========================================================================
class TestConfigPutEdgeCases:
    @pytest.mark.asyncio
    async def test_invalid_image_rejected(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "container_image": "nginx:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_shell_injection_in_extra_args(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "extra_args": "--flag; rm -rf /",
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_invalid_container_name(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "container_name": "-invalid",
                "container_image": "cloudflare/cloudflared:latest",
            },
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_additional_hosts_empty_hostname_rejected(self, client):
        """additional_hosts 中空 hostname 應被拒絕。"""
        resp = await client.put(
            "/api/config",
            json={
                "additional_hosts": [{"hostname": "", "service": "http://localhost:80"}],
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_additional_hosts_empty_service_rejected(self, client):
        resp = await client.put(
            "/api/config",
            json={
                "additional_hosts": [{"hostname": "app.io", "service": ""}],
                "container_image": "cloudflare/cloudflared:latest",
                "container_name": "cloudflared",
            },
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_empty_body_uses_defaults(self, client):
        """PUT 空 body（使用預設值）應成功。"""
        resp = await client.put("/api/config", json={})
        assert resp.status_code == 200
