"""
測試: ConfigManager 持久化與合併邏輯(本地管理版)
涵蓋: 預設值、缺鍵 merge、token 不落地、routes 多筆持久化、空 routes
"""

import json

import pytest

from backend.services.config_manager import ConfigManager, DEFAULT_CONFIG


@pytest.fixture()
def cfg_mgr(tmp_path):
    return ConfigManager(config_path=tmp_path / "settings.json")


@pytest.fixture()
def cfg_path(tmp_path):
    return tmp_path / "settings.json"


# =========================================================================
# 預設值 / 去 HA 化
# =========================================================================
class TestDefaultConfig:
    def test_default_config_has_no_ha_fields(self):
        assert "external_hostname" not in DEFAULT_CONFIG
        assert "nginx_proxy_manager" not in DEFAULT_CONFIG
        assert "additional_hosts" not in DEFAULT_CONFIG
        assert "container_name" not in DEFAULT_CONFIG
        assert "extra_args" not in DEFAULT_CONFIG
        assert "tunnel_token_secret" not in DEFAULT_CONFIG

    def test_default_config_new_fields(self):
        assert DEFAULT_CONFIG["mode"] == "local"
        assert DEFAULT_CONFIG["routes"] == []
        assert DEFAULT_CONFIG["catch_all_service"] == ""
        assert DEFAULT_CONFIG["tunnel_name"] == ""
        assert DEFAULT_CONFIG["post_quantum"] is False
        assert DEFAULT_CONFIG["log_level"] == "info"
        assert DEFAULT_CONFIG["run_parameters"] == ""
        assert DEFAULT_CONFIG["no_tls_verify"] is True

    @pytest.mark.asyncio
    async def test_load_creates_default_if_missing(self, cfg_mgr, cfg_path):
        result = await cfg_mgr.load()
        assert cfg_path.exists()
        assert result["mode"] == "local"
        assert result["routes"] == []
        assert result["catch_all_service"] == ""
        assert result["tunnel_name"] == ""
        assert result["no_tls_verify"] is True


# =========================================================================
# 缺鍵 merge(舊檔相容)
# =========================================================================
class TestMerge:
    @pytest.mark.asyncio
    async def test_load_merges_missing_keys(self, tmp_path):
        f = tmp_path / "settings.json"
        f.write_text('{"tunnel_name": "demo"}')
        mgr = ConfigManager(config_path=f)
        cfg = await mgr.load()
        assert cfg["tunnel_name"] == "demo"
        assert cfg["routes"] == []
        assert cfg["mode"] == "local"
        assert cfg["catch_all_service"] == ""

    @pytest.mark.asyncio
    async def test_existing_values_preserved(self, tmp_path):
        f = tmp_path / "settings.json"
        f.write_text(json.dumps({"mode": "token", "log_level": "debug"}))
        mgr = ConfigManager(config_path=f)
        cfg = await mgr.load()
        assert cfg["mode"] == "token"
        assert cfg["log_level"] == "debug"


# =========================================================================
# token 不落地
# =========================================================================
class TestTokenNotPersisted:
    @pytest.mark.asyncio
    async def test_save_strips_raw_token(self, cfg_mgr, cfg_path):
        await cfg_mgr.save({"tunnel_token": "SECRET", "tunnel_name": "x"})
        on_disk = json.loads(cfg_path.read_text())
        assert "tunnel_token" not in on_disk
        assert on_disk["tunnel_name"] == "x"


# =========================================================================
# routes 持久化
# =========================================================================
class TestRoutes:
    @pytest.mark.asyncio
    async def test_multiple_routes_persist(self, cfg_mgr):
        routes = [
            {"hostname": "a.io", "service": "http://localhost:3000", "disableChunkedEncoding": False},
            {"hostname": "b.io", "service": "http://localhost:4000", "disableChunkedEncoding": True},
            {"hostname": "c.io", "service": "http://localhost:5000", "disableChunkedEncoding": False},
        ]
        await cfg_mgr.save({"routes": routes})
        loaded = await cfg_mgr.load()
        assert len(loaded["routes"]) == 3
        assert loaded["routes"][1]["disableChunkedEncoding"] is True

    @pytest.mark.asyncio
    async def test_empty_routes_persist(self, cfg_mgr):
        await cfg_mgr.save(
            {"routes": [{"hostname": "x.io", "service": "http://localhost:1"}]}
        )
        await cfg_mgr.save({"routes": []})
        loaded = await cfg_mgr.load()
        assert loaded["routes"] == []

    @pytest.mark.asyncio
    async def test_save_merges_with_defaults(self, cfg_mgr):
        await cfg_mgr.save({"log_level": "error"})
        loaded = await cfg_mgr.load()
        assert loaded["log_level"] == "error"
        assert loaded["mode"] == "local"  # default
        assert loaded["routes"] == []  # default
        assert loaded["no_tls_verify"] is True  # default
