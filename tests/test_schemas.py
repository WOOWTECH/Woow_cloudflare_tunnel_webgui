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
# TunnelConfigWrite — 新增欄位與驗證器
# =========================================================================
class TestTunnelConfigWrite:
    """驗證 TunnelConfigWrite 的所有欄位和驗證邏輯。"""

    def _minimal(self, **overrides):
        base = {
            "post_quantum": False,
            "log_level": "info",
            "extra_args": "",
            "container_name": "cloudflared",
            "container_image": "cloudflare/cloudflared:latest",
        }
        base.update(overrides)
        return TunnelConfigWrite(**base)

    # --- 基本預設值 ---
    def test_defaults(self):
        cfg = self._minimal()
        assert cfg.external_hostname == ""
        assert cfg.additional_hosts == []
        assert cfg.tunnel_name == ""
        assert cfg.catch_all_service == ""
        assert cfg.nginx_proxy_manager is False
        assert cfg.tunnel_token is None

    # --- external_hostname ---
    def test_external_hostname_set(self):
        cfg = self._minimal(external_hostname="home.example.com")
        assert cfg.external_hostname == "home.example.com"

    def test_external_hostname_stripped(self):
        cfg = self._minimal(external_hostname="  home.example.com  ")
        assert cfg.external_hostname == "home.example.com"

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

    # --- nginx_proxy_manager ---
    def test_nginx_proxy_manager_true(self):
        cfg = self._minimal(nginx_proxy_manager=True)
        assert cfg.nginx_proxy_manager is True

    # --- additional_hosts ---
    def test_additional_hosts_single(self):
        cfg = self._minimal(
            additional_hosts=[
                {"hostname": "app.test.io", "service": "http://localhost:3000"}
            ]
        )
        assert len(cfg.additional_hosts) == 1
        assert cfg.additional_hosts[0].hostname == "app.test.io"

    def test_additional_hosts_multiple(self):
        cfg = self._minimal(
            additional_hosts=[
                {"hostname": "a.test.io", "service": "http://localhost:3000"},
                {
                    "hostname": "b.test.io",
                    "service": "http://localhost:4000",
                    "disableChunkedEncoding": True,
                },
            ]
        )
        assert len(cfg.additional_hosts) == 2
        assert cfg.additional_hosts[1].disableChunkedEncoding is True

    def test_additional_hosts_invalid_entry_rejected(self):
        with pytest.raises(ValidationError):
            self._minimal(
                additional_hosts=[
                    {"hostname": "", "service": "http://localhost:3000"}
                ]
            )

    def test_additional_hosts_empty_list_ok(self):
        cfg = self._minimal(additional_hosts=[])
        assert cfg.additional_hosts == []

    # --- extra_args 注入防護 ---
    @pytest.mark.parametrize(
        "bad_args",
        [
            "--flag; rm -rf /",
            "--flag & wget evil",
            "--flag | cat /etc/passwd",
            "--flag `whoami`",
            "--flag $(id)",
            "--flag(){echo}",
        ],
    )
    def test_extra_args_shell_injection_rejected(self, bad_args):
        with pytest.raises(ValidationError) as exc_info:
            self._minimal(extra_args=bad_args)
        assert "disallowed shell characters" in str(exc_info.value)

    def test_extra_args_safe_value(self):
        cfg = self._minimal(extra_args="--protocol quic --edge-ip-version auto")
        assert cfg.extra_args == "--protocol quic --edge-ip-version auto"

    # --- container_name 驗證 ---
    @pytest.mark.parametrize(
        "bad_name",
        [
            "",
            "-invalid",
            ".invalid",
            "_invalid",
            "name with spaces",
            "name;inject",
            "name&inject",
        ],
    )
    def test_container_name_invalid_rejected(self, bad_name):
        with pytest.raises(ValidationError):
            self._minimal(container_name=bad_name)

    def test_container_name_valid_variants(self):
        for name in ["cloudflared", "cf-tunnel-1", "my_tunnel.v2", "Tunnel123"]:
            cfg = self._minimal(container_name=name)
            assert cfg.container_name == name

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
            tunnel_token_secret="cf-tunnel-token",
            tunnel_token_masked="****",
            external_hostname="home.example.com",
            additional_hosts=[
                AdditionalHost(hostname="a.io", service="http://localhost:80")
            ],
            tunnel_name="my-tunnel",
            catch_all_service="http://localhost:80",
            nginx_proxy_manager=True,
        )
        assert cfg.external_hostname == "home.example.com"
        assert len(cfg.additional_hosts) == 1
        assert cfg.tunnel_name == "my-tunnel"
        assert cfg.catch_all_service == "http://localhost:80"
        assert cfg.nginx_proxy_manager is True


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
