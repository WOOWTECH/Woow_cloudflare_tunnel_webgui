"""
測試: PUT /api/config 與 HA add-on options 對齊的語意
涵蓋: token 保留/移除/替換、貼上安裝指令、無效 token 的 422 不回傳輸入、
run_parameters 白名單與舊字串格式、token 模式必須有 token、?restart=true 套用、health 欄位
"""

import json

import pytest

from tests.conftest import make_token


@pytest.mark.asyncio
async def test_null_keeps_empty_removes_value_replaces(client, tmp_config_dir):
    token_file = tmp_config_dir / ".tunnel_token"
    first, second = make_token(secret="Zmlyc3Q"), make_token(secret="c2Vjb25k")
    await client.put("/api/config", json={"tunnel_token": first})
    await client.put("/api/config", json={"tunnel_name": "x"})
    assert token_file.read_text() == first
    await client.put("/api/config", json={"tunnel_token": second})
    assert token_file.read_text() == second
    resp = await client.put("/api/config", json={"tunnel_token": ""})
    assert not token_file.exists()
    assert resp.json()["tunnel_token_set"] is False


@pytest.mark.asyncio
async def test_pasted_install_command_stores_only_the_token(client, tmp_config_dir):
    token = make_token()
    resp = await client.put("/api/config", json={
        "tunnel_token": f"  sudo cloudflared service install {token}\n"})
    assert resp.status_code == 200
    assert (tmp_config_dir / ".tunnel_token").read_text() == token
    assert (tmp_config_dir / ".tunnel_token").stat().st_mode & 0o777 == 0o600


@pytest.mark.asyncio
async def test_invalid_token_is_rejected_without_echoing_it(client, tmp_config_dir):
    resp = await client.put("/api/config", json={"tunnel_token": "PRIVATE-not-a-token"})
    assert resp.status_code == 422
    assert "PRIVATE-not-a-token" not in resp.text
    assert resp.json()["detail"][0]["loc"] == ["body", "tunnel_token"]
    assert not (tmp_config_dir / ".tunnel_token").exists()


@pytest.mark.asyncio
@pytest.mark.parametrize("param", ["--token=abc", "--token-file=/tmp/x", "--metrics=0.0.0.0:1", "--foo=bar"])
async def test_run_parameters_outside_the_allow_list_are_rejected(client, param):
    resp = await client.put("/api/config", json={"run_parameters": [param]})
    assert resp.status_code == 422
    assert param not in resp.text


@pytest.mark.asyncio
async def test_run_parameters_round_trip(client):
    resp = await client.put("/api/config", json={"run_parameters": ["--protocol=http2", " ", "--tag=a=b"]})
    assert resp.json()["run_parameters"] == ["--protocol=http2", "--tag=a=b"]


@pytest.mark.asyncio
async def test_legacy_string_settings_are_migrated(client, tmp_config_dir):
    (tmp_config_dir / "settings.json").write_text(json.dumps(
        {"run_parameters": "--protocol quic --region=us", "log_level": "warning"}))
    data = (await client.get("/api/config")).json()
    assert data["run_parameters"] == ["--protocol=quic", "--region=us"]
    assert data["log_level"] == "warn"


@pytest.mark.asyncio
async def test_token_mode_without_a_token_is_rejected(client):
    resp = await client.put("/api/config", json={"mode": "token"})
    assert resp.status_code == 422
    assert "token" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_save_with_restart_applies_the_new_settings(client, mock_pm):
    resp = await client.put("/api/config?restart=true",
                            json={"mode": "token", "tunnel_token": make_token(), "post_quantum": True})
    assert resp.status_code == 200
    assert "--post-quantum" in mock_pm.start.await_args.args[0]


@pytest.mark.asyncio
async def test_save_with_restart_reports_why_it_could_not_apply(client, mock_pm):
    resp = await client.put("/api/config?restart=true", json={"tunnel_name": "x"})
    assert resp.status_code == 409
    assert resp.json()["detail"].startswith("設定已儲存")
    assert (await client.get("/api/config")).json()["tunnel_name"] == "x"
    mock_pm.start.assert_not_awaited()


@pytest.mark.asyncio
async def test_health_reports_version_and_edge_connections(client, tunnel_status):
    from backend import __version__

    tunnel_status.status, tunnel_status.ready_connections = "running", 4
    data = (await client.get("/api/health")).json()
    assert data["version"] == __version__
    assert data["tunnel"] == {"status": "running", "ready_connections": 4, "metrics_reachable": False}
    assert data["stopped_by_operator"] is False
