"""
測試: Config API 端點整合測試(本地管理版)
涵蓋: GET 回 masked + 新欄位、PUT 設 token 走 token_store、routes 持久化、錯誤處理
"""

import pytest


# =========================================================================
# GET /api/config
# =========================================================================
class TestConfigGet:
    @pytest.mark.asyncio
    async def test_get_returns_new_fields(self, client):
        resp = await client.get("/api/config")
        assert resp.status_code == 200
        data = resp.json()
        for key in [
            "mode",
            "tunnel_name",
            "routes",
            "catch_all_service",
            "post_quantum",
            "log_level",
            "run_parameters",
            "no_tls_verify",
            "tunnel_token_masked",
        ]:
            assert key in data, f"Missing field: {key}"

    @pytest.mark.asyncio
    async def test_get_default_values(self, client):
        resp = await client.get("/api/config")
        data = resp.json()
        assert data["mode"] == "local"
        assert data["routes"] == []
        assert data["catch_all_service"] == ""
        assert data["tunnel_name"] == ""
        assert data["post_quantum"] is False
        assert data["log_level"] == "info"
        assert data["no_tls_verify"] is True

    @pytest.mark.asyncio
    async def test_get_masks_token(self, client):
        resp = await client.get("/api/config")
        data = resp.json()
        assert "tunnel_token" not in data  # raw token 不應出現
        assert data["tunnel_token_masked"] == ""  # 尚未設定


# =========================================================================
# PUT /api/config — token 走 token_store
# =========================================================================
class TestConfigPutToken:
    @pytest.mark.asyncio
    async def test_put_sets_token_returns_masked(self, client):
        resp = await client.put(
            "/api/config",
            json={"tunnel_token": "my-super-secret-token"},
        )
        assert resp.status_code == 200
        assert resp.json()["tunnel_token_masked"] == "********"

    @pytest.mark.asyncio
    async def test_put_token_then_get_masked(self, client):
        await client.put("/api/config", json={"tunnel_token": "another-secret"})
        resp = await client.get("/api/config")
        assert resp.json()["tunnel_token_masked"] == "********"


# =========================================================================
# PUT /api/config — 新欄位
# =========================================================================
class TestConfigPutNewFields:
    @pytest.mark.asyncio
    async def test_put_tunnel_name(self, client):
        resp = await client.put("/api/config", json={"tunnel_name": "my-test-tunnel"})
        assert resp.status_code == 200
        assert resp.json()["tunnel_name"] == "my-test-tunnel"

    @pytest.mark.asyncio
    async def test_put_mode_token(self, client):
        resp = await client.put("/api/config", json={"mode": "token"})
        assert resp.status_code == 200
        assert resp.json()["mode"] == "token"

    @pytest.mark.asyncio
    async def test_put_catch_all_service(self, client):
        resp = await client.put(
            "/api/config", json={"catch_all_service": "http://localhost:80"}
        )
        assert resp.status_code == 200
        assert resp.json()["catch_all_service"] == "http://localhost:80"

    @pytest.mark.asyncio
    async def test_put_no_tls_verify_false(self, client):
        resp = await client.put("/api/config", json={"no_tls_verify": False})
        assert resp.status_code == 200
        assert resp.json()["no_tls_verify"] is False

    @pytest.mark.asyncio
    async def test_put_routes(self, client):
        routes = [
            {"hostname": "app.test.io", "service": "http://localhost:3000"},
            {
                "hostname": "api.test.io",
                "service": "http://localhost:4000",
                "disableChunkedEncoding": True,
            },
        ]
        resp = await client.put("/api/config", json={"routes": routes})
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["routes"]) == 2
        assert data["routes"][0]["hostname"] == "app.test.io"
        assert data["routes"][1]["disableChunkedEncoding"] is True

    @pytest.mark.asyncio
    async def test_put_then_get_consistency(self, client):
        payload = {
            "tunnel_name": "persist-tunnel",
            "mode": "token",
            "routes": [{"hostname": "a.io", "service": "http://localhost:3000"}],
        }
        await client.put("/api/config", json=payload)
        resp = await client.get("/api/config")
        data = resp.json()
        assert data["tunnel_name"] == "persist-tunnel"
        assert data["mode"] == "token"
        assert len(data["routes"]) == 1


# =========================================================================
# PUT /api/config — 錯誤處理 & 邊緣條件
# =========================================================================
class TestConfigPutEdgeCases:
    @pytest.mark.asyncio
    async def test_invalid_log_level_rejected(self, client):
        resp = await client.put("/api/config", json={"log_level": "verbose"})
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_invalid_route_hostname_rejected(self, client):
        resp = await client.put(
            "/api/config",
            json={"routes": [{"hostname": "app.io:8123", "service": "http://x"}]},
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_empty_route_hostname_rejected(self, client):
        resp = await client.put(
            "/api/config",
            json={"routes": [{"hostname": "", "service": "http://localhost:80"}]},
        )
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_invalid_mode_rejected(self, client):
        resp = await client.put("/api/config", json={"mode": "bogus"})
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_empty_body_uses_defaults(self, client):
        resp = await client.put("/api/config", json={})
        assert resp.status_code == 200
        assert resp.json()["mode"] == "local"
