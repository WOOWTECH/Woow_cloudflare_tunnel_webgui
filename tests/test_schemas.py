"""
測試 1: Pydantic Schema 模型驗證
涵蓋: AdditionalHost, LogLevel, TunnelConfigWrite 的邊緣條件
"""

import pytest
from pydantic import ValidationError

from backend.models.schemas import (
    AdditionalHost,
    LogLevel,
    TunnelConfigRead,
    TunnelConfigWrite,
    ContainerStatus,
)


# =========================================================================
# LogLevel 列舉
# =========================================================================
class TestLogLevel:
    """驗證所有 8 個日誌等級都能正確解析。"""

    @pytest.mark.parametrize(
        "level",
        ["trace", "debug", "info", "notice", "warn", "warning", "error", "fatal"],
    )
    def test_valid_log_levels(self, level):
        assert LogLevel(level).value == level

    def test_invalid_log_level_rejected(self):
        with pytest.raises(ValueError):
            LogLevel("verbose")

    def test_invalid_log_level_case_sensitive(self):
        with pytest.raises(ValueError):
            LogLevel("INFO")


# =========================================================================
# AdditionalHost 模型
# =========================================================================
class TestAdditionalHost:
    """驗證 AdditionalHost 的欄位驗證邏輯。"""

    def test_valid_host(self):
        h = AdditionalHost(hostname="app.example.com", service="http://localhost:3000")
        assert h.hostname == "app.example.com"
        assert h.service == "http://localhost:3000"
        assert h.disableChunkedEncoding is False

    def test_disable_chunked_encoding_true(self):
        h = AdditionalHost(
            hostname="app.example.com",
            service="http://localhost:3000",
            disableChunkedEncoding=True,
        )
        assert h.disableChunkedEncoding is True

    def test_hostname_empty_rejected(self):
        with pytest.raises(ValidationError) as exc_info:
            AdditionalHost(hostname="", service="http://localhost:3000")
        assert "Hostname cannot be empty" in str(exc_info.value)

    def test_hostname_whitespace_only_rejected(self):
        with pytest.raises(ValidationError):
            AdditionalHost(hostname="   ", service="http://localhost:3000")

    def test_service_empty_rejected(self):
        with pytest.raises(ValidationError) as exc_info:
            AdditionalHost(hostname="app.example.com", service="")
        assert "Service URL cannot be empty" in str(exc_info.value)

    def test_service_whitespace_only_rejected(self):
        with pytest.raises(ValidationError):
            AdditionalHost(hostname="app.example.com", service="   ")

    def test_hostname_stripped(self):
        h = AdditionalHost(hostname="  app.example.com  ", service="http://localhost:80")
        assert h.hostname == "app.example.com"

    def test_service_stripped(self):
        h = AdditionalHost(hostname="app.example.com", service="  http://localhost:80  ")
        assert h.service == "http://localhost:80"

    def test_missing_hostname_rejected(self):
        with pytest.raises(ValidationError):
            AdditionalHost(service="http://localhost:3000")

    def test_missing_service_rejected(self):
        with pytest.raises(ValidationError):
            AdditionalHost(hostname="app.example.com")


# =========================================================================
# TunnelConfigWrite — 本地管理新欄位
# =========================================================================
class TestTunnelConfigWrite:
    """驗證 TunnelConfigWrite 的所有欄位和驗證邏輯。"""

    def _minimal(self, **overrides):
        base = {}
        base.update(overrides)
        return TunnelConfigWrite(**base)

    # --- 基本預設值 ---
    def test_defaults(self):
        cfg = self._minimal()
        assert cfg.mode.value == "local"
        assert cfg.tunnel_name == ""
        assert cfg.routes == []
        assert cfg.catch_all_service == ""
        assert cfg.post_quantum is False
        assert cfg.log_level == LogLevel.info
        assert cfg.run_parameters == ""
        assert cfg.no_tls_verify is True
        assert cfg.tunnel_token is None

    # --- mode ---
    def test_mode_token(self):
        cfg = self._minimal(mode="token")
        assert cfg.mode.value == "token"

    def test_invalid_mode_rejected(self):
        with pytest.raises(ValidationError):
            self._minimal(mode="bogus")

    # --- tunnel_name ---
    def test_tunnel_name_set(self):
        cfg = self._minimal(tunnel_name="my-tunnel")
        assert cfg.tunnel_name == "my-tunnel"

    # --- catch_all_service ---
    def test_catch_all_service_set(self):
        cfg = self._minimal(catch_all_service="http://localhost:80")
        assert cfg.catch_all_service == "http://localhost:80"

    def test_catch_all_service_stripped(self):
        cfg = self._minimal(catch_all_service="  http://localhost:80  ")
        assert cfg.catch_all_service == "http://localhost:80"

    # --- no_tls_verify ---
    def test_no_tls_verify_false(self):
        cfg = self._minimal(no_tls_verify=False)
        assert cfg.no_tls_verify is False

    # --- routes ---
    def test_routes_single(self):
        cfg = self._minimal(
            routes=[{"hostname": "app.test.io", "service": "http://localhost:3000"}]
        )
        assert len(cfg.routes) == 1
        assert cfg.routes[0].hostname == "app.test.io"

    def test_routes_multiple(self):
        cfg = self._minimal(
            routes=[
                {"hostname": "a.test.io", "service": "http://localhost:3000"},
                {
                    "hostname": "b.test.io",
                    "service": "http://localhost:4000",
                    "disableChunkedEncoding": True,
                },
            ]
        )
        assert len(cfg.routes) == 2
        assert cfg.routes[1].disableChunkedEncoding is True

    def test_routes_invalid_hostname_rejected(self):
        with pytest.raises(ValidationError):
            self._minimal(routes=[{"hostname": "", "service": "http://localhost:3000"}])

    def test_routes_hostname_with_port_rejected(self):
        with pytest.raises(ValidationError):
            self._minimal(
                routes=[{"hostname": "app.test.io:8123", "service": "http://x"}]
            )

    def test_routes_empty_list_ok(self):
        cfg = self._minimal(routes=[])
        assert cfg.routes == []

    # --- log_level ---
    def test_all_log_levels_accepted(self):
        for level in ["trace", "debug", "info", "notice", "warn", "warning", "error", "fatal"]:
            cfg = self._minimal(log_level=level)
            assert cfg.log_level == LogLevel(level)

    def test_invalid_log_level_rejected(self):
        with pytest.raises(ValidationError):
            self._minimal(log_level="verbose")


# =========================================================================
# TunnelConfigRead
# =========================================================================
class TestTunnelConfigRead:
    def test_read_includes_new_fields(self):
        cfg = TunnelConfigRead(
            mode="local",
            tunnel_name="my-tunnel",
            routes=[Route(hostname="a.io", service="http://localhost:80")],
            catch_all_service="http://localhost:80",
            no_tls_verify=True,
            tunnel_token_masked="********",
        )
        assert cfg.mode.value == "local"
        assert cfg.tunnel_name == "my-tunnel"
        assert len(cfg.routes) == 1
        assert cfg.catch_all_service == "http://localhost:80"
        assert cfg.tunnel_token_masked == "********"

    def test_read_defaults(self):
        cfg = TunnelConfigRead()
        assert cfg.mode.value == "local"
        assert cfg.routes == []
        assert cfg.tunnel_token_masked == ""


# =========================================================================
# ContainerStatus 列舉完整性
# =========================================================================
class TestContainerStatus:
    @pytest.mark.parametrize(
        "status",
        [
            "running", "stopped", "exited", "created",
            "paused", "restarting", "removing", "dead",
            "not_found", "unknown",
        ],
    )
    def test_all_statuses_valid(self, status):
        assert ContainerStatus(status).value == status

    def test_invalid_status_rejected(self):
        with pytest.raises(ValueError):
            ContainerStatus("nonexistent")


# =========================================================================
# Phase 2: 本地管理新模型 (TunnelMode / Route / SetupState)
# =========================================================================
from backend.models.schemas import TunnelMode


def test_tunnel_mode_values():
    assert TunnelMode.local.value == "local"
    assert TunnelMode.token.value == "token"


from backend.models.schemas import Route


def test_route_accepts_valid_hostname_and_service():
    r = Route(hostname="app.example.com", service="http://localhost:8080")
    assert r.hostname == "app.example.com"
    assert r.service == "http://localhost:8080"
    assert r.disableChunkedEncoding is False   # 預設


@pytest.mark.parametrize("bad", [
    "https://app.example.com",   # 含協定
    "app.example.com:8123",      # 含埠
    "App.Example.com",           # 大寫(會被 lower 後仍合法 → 見下說明)
    "",                          # 空
    "   ",                       # 純空白
])
def test_route_rejects_invalid_hostname(bad):
    if bad.strip().lower() == "app.example.com":
        pytest.skip("大寫會被正規化為合法,改由 2.4 驗證")
    with pytest.raises(ValidationError):
        Route(hostname=bad, service="http://x")


def test_route_lowercases_hostname():
    r = Route(hostname="App.Example.COM", service="http://x")
    assert r.hostname == "app.example.com"


from backend.models.schemas import SetupState


def test_setup_state_serializes():
    s = SetupState(has_cert=False, has_tunnel=False, tunnel_uuid=None,
                   mode=TunnelMode.local)
    d = s.model_dump()
    assert d == {"has_cert": False, "has_tunnel": False,
                 "tunnel_uuid": None, "mode": "local"}
