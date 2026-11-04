"""
測試: services/runtime(每次啟動都以目前設定重建 argv 與 ingress)
涵蓋: run_parameters 放在 run 之前、DNS 只建立新 hostname、沒有路由時保留既有 config.json、
ingress 驗證失敗不啟動、憑證檔不安全時不啟動並回報 health、開機自動啟動尊重 Stop
"""

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.services import runtime
from backend.services.config_manager import ConfigManager
from backend.services.token_store import TokenStore
from tests.conftest import make_token


@pytest.fixture()
def deps(tmp_path, mock_cli, mock_pm):
    (tmp_path / "cert.pem").write_text("CERT")
    (tmp_path / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    return dict(pm=mock_pm, config_mgr=ConfigManager(tmp_path / "settings.json"),
                token_store=TokenStore(tmp_path / ".tunnel_token"), cli=mock_cli,
                data_dir=tmp_path)


async def _apply(deps, **cfg):
    current = await deps["config_mgr"].load()
    await deps["config_mgr"].save({**current, **cfg})
    return await runtime.apply(**deps)


@pytest.mark.asyncio
async def test_run_parameters_and_options_reach_cloudflared_before_run(deps):
    args = await _apply(deps, routes=[{"hostname": "a.example.com", "service": "http://localhost:1"}],
                        run_parameters=["--protocol=http2", "--region=us"], post_quantum=True,
                        log_level="debug")
    run = args.index("run")
    assert args.index("--protocol=http2") < run and args.index("--region=us") < run
    assert "--post-quantum" in args and args[args.index("--loglevel") + 1] == "debug"
    assert args[args.index("--metrics") + 1] == "127.0.0.1:20241"


@pytest.mark.asyncio
async def test_ingress_is_regenerated_from_settings(deps):
    await _apply(deps, routes=[{"hostname": "a.example.com", "service": "http://localhost:1"}],
                 catch_all_service="http://localhost:80")
    config = json.loads((deps["data_dir"] / "config.json").read_text())
    assert config["ingress"][0]["hostname"] == "a.example.com"
    assert config["ingress"][-1]["service"] == "http://localhost:80"


@pytest.mark.asyncio
async def test_dns_is_routed_only_for_new_hostnames(deps):
    routes = [{"hostname": "a.example.com", "service": "http://localhost:1"}]
    await _apply(deps, routes=routes)
    await _apply(deps, routes=routes)
    assert deps["cli"].route_dns.await_count == 1
    await _apply(deps, routes=routes + [{"hostname": "b.example.com", "service": "http://localhost:2"}])
    assert deps["cli"].route_dns.await_count == 2


@pytest.mark.asyncio
async def test_existing_config_json_is_kept_when_settings_have_no_routes(deps):
    legacy = {"tunnel": "uuid-test", "ingress": [{"hostname": "ssh.example.com", "service": "ssh://localhost:22"}]}
    (deps["data_dir"] / "config.json").write_text(json.dumps(legacy))
    await runtime.apply(**deps)
    assert json.loads((deps["data_dir"] / "config.json").read_text()) == legacy
    deps["cli"].ingress_validate.assert_not_awaited()


@pytest.mark.asyncio
async def test_invalid_ingress_does_not_start(deps):
    deps["cli"].ingress_validate.return_value = (False, "duplicate hostname")
    with pytest.raises(runtime.TunnelStartError) as info:
        await _apply(deps, routes=[{"hostname": "a.example.com", "service": "http://localhost:1"}])
    assert info.value.status == 422
    deps["pm"].start.assert_not_awaited()


@pytest.mark.asyncio
async def test_token_mode_needs_a_token(deps):
    with pytest.raises(runtime.TunnelStartError):
        await _apply(deps, mode="token")
    deps["token_store"].set(make_token())
    args = await _apply(deps, mode="token")
    assert args[-2:] == ["--token-file", str(deps["data_dir"] / ".tunnel_token")]


@pytest.mark.asyncio
async def test_unsafe_credential_blocks_start_and_shows_in_health(deps, client, tmp_config_dir):
    (deps["data_dir"] / "cert.pem").unlink()
    (deps["data_dir"] / "elsewhere").write_text("x")
    (deps["data_dir"] / "cert.pem").symlink_to(deps["data_dir"] / "elsewhere")
    with pytest.raises(runtime.TunnelStartError):
        await runtime.apply(**deps)
    deps["pm"].start.assert_not_awaited()
    health = (await client.get("/api/health")).json()
    assert health["credentials_error"] and "cert.pem" in health["credentials_error"]
    runtime.credentials_error = None


@pytest.mark.asyncio
async def test_boot_autostart_honours_an_operator_stop(tmp_path, monkeypatch):
    from backend import main

    (tmp_path / "settings.json").write_text('{"mode": "token"}')
    (tmp_path / ".tunnel_token").write_text(make_token())
    (tmp_path / ".tunnel_stopped").touch()
    pm = MagicMock()
    pm.is_running.return_value = False
    pm.start = AsyncMock()
    pm.stop = AsyncMock()
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main.tunnel, "pm", pm)
    monkeypatch.setattr(main.tunnel, "config_mgr", ConfigManager(tmp_path / "settings.json"))
    monkeypatch.setattr(main.tunnel, "token_store", TokenStore(tmp_path / ".tunnel_token"))
    monkeypatch.setenv("PAAS_LINK_STATE", str(tmp_path / "paas-link.json"))
    async with main.lifespan(main.app):
        pass
    pm.start.assert_not_awaited()
    (tmp_path / ".tunnel_stopped").unlink()
    async with main.lifespan(main.app):
        pass
    pm.start.assert_awaited_once()
