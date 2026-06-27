"""
測試: Tunnel API 端點(本地管理版,走 ProcessManager)
涵蓋: stop 呼叫 pm.stop、status running、start/restart
"""

import pytest


@pytest.mark.asyncio
async def test_tunnel_stop_calls_pm(client, mock_pm):
    resp = await client.post("/api/tunnel/stop")
    assert resp.status_code == 200
    mock_pm.stop.assert_awaited_once()


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
async def test_tunnel_restart_calls_pm(client, mock_pm):
    resp = await client.post("/api/tunnel/restart")
    assert resp.status_code == 200
    mock_pm.restart.assert_awaited_once()


@pytest.mark.asyncio
async def test_tunnel_start_calls_pm(client, mock_pm):
    resp = await client.post("/api/tunnel/start")
    assert resp.status_code == 200
    mock_pm.start.assert_awaited_once()
