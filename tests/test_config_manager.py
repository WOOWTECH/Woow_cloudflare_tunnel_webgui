"""
測試 2: ConfigManager 持久化與合併邏輯
涵蓋: 檔案建立、合併預設值、新增欄位遷移、token 不外洩
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
# 初始化行為
# =========================================================================
class TestConfigManagerInit:
    @pytest.mark.asyncio
    async def test_load_creates_default_if_missing(self, cfg_mgr, cfg_path):
        """首次 load 時應自動建立 settings.json 並回傳預設值。"""
        result = await cfg_mgr.load()
        assert cfg_path.exists()
        assert result["post_quantum"] is False
        assert result["log_level"] == "info"
        assert result["external_hostname"] == ""
        assert result["additional_hosts"] == []
        assert result["tunnel_name"] == ""
        assert result["catch_all_service"] == ""
        assert result["nginx_proxy_manager"] is False

    @pytest.mark.asyncio
    async def test_default_config_has_all_new_fields(self, cfg_mgr):
        """DEFAULT_CONFIG 必須包含所有 HAOS 新欄位。"""
        for key in [
            "external_hostname",
            "additional_hosts",
            "tunnel_name",
            "catch_all_service",
            "nginx_proxy_manager",
        ]:
            assert key in DEFAULT_CONFIG, f"Missing key: {key}"


# =========================================================================
# 儲存與讀取
# =========================================================================
class TestConfigManagerSaveLoad:
    @pytest.mark.asyncio
    async def test_save_and_reload(self, cfg_mgr):
        """儲存後重新讀取應回傳相同資料。"""
        await cfg_mgr.save(
            {
                "post_quantum": True,
                "log_level": "debug",
                "external_hostname": "home.test.io",
                "tunnel_name": "test-tunnel",
                "catch_all_service": "http://localhost:80",
                "nginx_proxy_manager": True,
                "additional_hosts": [
                    {
                        "hostname": "app.test.io",
                        "service": "http://localhost:3000",
                        "disableChunkedEncoding": True,
                    }
                ],
            }
        )
        loaded = await cfg_mgr.load()
        assert loaded["post_quantum"] is True
        assert loaded["log_level"] == "debug"
        assert loaded["external_hostname"] == "home.test.io"
        assert loaded["tunnel_name"] == "test-tunnel"
        assert loaded["catch_all_service"] == "http://localhost:80"
        assert loaded["nginx_proxy_manager"] is True
        assert len(loaded["additional_hosts"]) == 1
        assert loaded["additional_hosts"][0]["disableChunkedEncoding"] is True

    @pytest.mark.asyncio
    async def test_token_never_persisted(self, cfg_mgr, cfg_path):
        """tunnel_token 欄位不應寫入 settings.json。"""
        await cfg_mgr.save({"tunnel_token": "super-secret-token"})
        raw = json.loads(cfg_path.read_text())
        assert "tunnel_token" not in raw

    @pytest.mark.asyncio
    async def test_save_merges_with_defaults(self, cfg_mgr):
        """只儲存部分欄位時，其餘應保持預設值。"""
        await cfg_mgr.save({"log_level": "error"})
        loaded = await cfg_mgr.load()
        assert loaded["log_level"] == "error"
        assert loaded["container_name"] == "cloudflared"  # default
        assert loaded["external_hostname"] == ""  # default
        assert loaded["nginx_proxy_manager"] is False  # default


# =========================================================================
# 舊版 config 相容性（遷移）
# =========================================================================
class TestConfigManagerMigration:
    @pytest.mark.asyncio
    async def test_old_config_missing_new_fields(self, tmp_path):
        """
        模擬舊版 settings.json 不含新欄位的情境。
        load() 應自動補上 DEFAULT_CONFIG 中的預設值。
        """
        old_config = {
            "tunnel_token_secret": "cf-tunnel-token",
            "post_quantum": False,
            "log_level": "info",
            "extra_args": "",
            "container_name": "cloudflared",
            "container_image": "cloudflare/cloudflared:latest",
        }
        cfg_path = tmp_path / "settings.json"
        cfg_path.write_text(json.dumps(old_config))

        mgr = ConfigManager(config_path=cfg_path)
        loaded = await mgr.load()

        # 新欄位應自動補上
        assert loaded["external_hostname"] == ""
        assert loaded["additional_hosts"] == []
        assert loaded["tunnel_name"] == ""
        assert loaded["catch_all_service"] == ""
        assert loaded["nginx_proxy_manager"] is False

    @pytest.mark.asyncio
    async def test_old_config_preserves_existing_values(self, tmp_path):
        """舊版 config 的既有欄位值不應被覆蓋。"""
        old_config = {
            "tunnel_token_secret": "cf-tunnel-token",
            "post_quantum": True,
            "log_level": "debug",
            "extra_args": "--protocol quic",
            "container_name": "my-cloudflared",
            "container_image": "cloudflare/cloudflared:latest",
        }
        cfg_path = tmp_path / "settings.json"
        cfg_path.write_text(json.dumps(old_config))

        mgr = ConfigManager(config_path=cfg_path)
        loaded = await mgr.load()

        assert loaded["post_quantum"] is True
        assert loaded["log_level"] == "debug"
        assert loaded["extra_args"] == "--protocol quic"
        assert loaded["container_name"] == "my-cloudflared"


# =========================================================================
# Additional Hosts 持久化
# =========================================================================
class TestConfigManagerAdditionalHosts:
    @pytest.mark.asyncio
    async def test_multiple_hosts_persist(self, cfg_mgr):
        """多筆 additional_hosts 應完整持久化。"""
        hosts = [
            {"hostname": "a.io", "service": "http://localhost:3000", "disableChunkedEncoding": False},
            {"hostname": "b.io", "service": "http://localhost:4000", "disableChunkedEncoding": True},
            {"hostname": "c.io", "service": "http://localhost:5000", "disableChunkedEncoding": False},
        ]
        await cfg_mgr.save({"additional_hosts": hosts})
        loaded = await cfg_mgr.load()
        assert len(loaded["additional_hosts"]) == 3
        assert loaded["additional_hosts"][1]["disableChunkedEncoding"] is True

    @pytest.mark.asyncio
    async def test_empty_hosts_persist(self, cfg_mgr):
        """清空 additional_hosts 後應回傳空列表。"""
        await cfg_mgr.save(
            {"additional_hosts": [{"hostname": "x.io", "service": "http://localhost:1"}]}
        )
        await cfg_mgr.save({"additional_hosts": []})
        loaded = await cfg_mgr.load()
        assert loaded["additional_hosts"] == []
