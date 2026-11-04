"""
測試: Tunnel API 端點(本地管理版,走 ProcessManager)
涵蓋: stop 呼叫 pm.stop 並留下 stopped 標記、status、start/restart 以目前設定重建 argv、
未設定時拒絕啟動
"""

import pytest

from tests.conftest import make_token


def _local_ready(data_dir):
    (data_dir / "cert.pem").write_text("CERT")
    (data_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    (data_dir / "config.json").write_text("{}")


@pytest.mark.asyncio
async def test_tunnel_stop_calls_pm_and_stays_temporary(client, mock_pm, tmp_config_dir):
    resp = await client.post("/api/tunnel/stop")
    assert resp.status_code == 200
    mock_pm.stop.assert_awaited_once()
    # A GUI Stop must not keep the tunnel down: on a host where it is the only
    # remote path the healthcheck brings it back (README, "Known behaviour").
    assert not (tmp_config_dir / ".tunnel_stopped").exists()


@pytest.mark.asyncio
async def test_status_reports_a_hand_made_stop_marker(client, tmp_config_dir):
    (tmp_config_dir / ".tunnel_stopped").touch()
    assert (await client.get("/api/tunnel/status")).json()["stopped_by_operator"] is True


@pytest.mark.asyncio
async def test_tunnel_status_running(client, mock_pm):
    resp = await client.get("/api/tunnel/status")
    assert resp.status_code == 200
    assert resp.json()["running"] is True


@pytest.mark.asyncio
async def test_tunnel_status_not_running(client, mock_pm):
    mock_pm.is_running.return_value = False
    resp = await client.get("/api/tunnel/status")
    assert resp.json()["running"] is False


@pytest.mark.asyncio
async def test_tunnel_start_clears_the_stop_marker(client, mock_pm, tmp_config_dir):
    _local_ready(tmp_config_dir)
    (tmp_config_dir / ".tunnel_stopped").touch()
    resp = await client.post("/api/tunnel/start")
    assert resp.status_code == 200
    mock_pm.start.assert_awaited_once()
    assert not (tmp_config_dir / ".tunnel_stopped").exists()


@pytest.mark.asyncio
async def test_tunnel_start_refuses_when_not_configured(client, mock_pm):
    resp = await client.post("/api/tunnel/start")
    assert resp.status_code == 409
    assert "Setup" in resp.json()["detail"]
    mock_pm.start.assert_not_awaited()


@pytest.mark.asyncio
async def test_tunnel_restart_uses_the_current_settings(client, mock_pm, tmp_config_dir):
    # ProcessManager.restart() would re-run the old argv; a saved change must apply.
    _local_ready(tmp_config_dir)
    resp = await client.put("/api/config", json={"post_quantum": True})
    assert resp.status_code == 200
    resp = await client.post("/api/tunnel/restart")
    assert resp.status_code == 200
    mock_pm.restart.assert_not_awaited()
    assert "--post-quantum" in mock_pm.start.await_args.args[0]


@pytest.mark.asyncio
async def test_tunnel_start_in_token_mode_passes_a_token_file_not_the_token(
        client, mock_pm, tmp_config_dir):
    secret = make_token()
    resp = await client.put("/api/config", json={"mode": "token", "tunnel_token": secret})
    assert resp.status_code == 200
    resp = await client.post("/api/tunnel/start")
    assert resp.status_code == 200
    args = mock_pm.start.await_args.args[0]
    assert args[-2:] == ["--token-file", str(tmp_config_dir / ".tunnel_token")]
    assert not any(secret in a for a in args)
    assert "--token" not in args
