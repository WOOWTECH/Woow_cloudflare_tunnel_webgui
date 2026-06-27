"""
測試: Setup 上線精靈 API
涵蓋: state / create tunnel / apply(成功 + 驗證失敗)/ login WS
"""

import pytest


# =========================================================================
# GET /api/setup/state
# =========================================================================
@pytest.mark.asyncio
async def test_setup_state_reports_no_cert(client, tmp_config_dir, monkeypatch):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    resp = await client.get("/api/setup/state")
    assert resp.status_code == 200
    body = resp.json()
    assert body["has_cert"] is False
    assert body["has_tunnel"] is False
    assert body["mode"] in ("local", "token")


@pytest.mark.asyncio
async def test_setup_state_detects_cert_and_tunnel(client, tmp_config_dir, monkeypatch):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "cert.pem").write_text("CERT")
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-abc"}')
    resp = await client.get("/api/setup/state")
    body = resp.json()
    assert body["has_cert"] is True
    assert body["has_tunnel"] is True
    assert body["tunnel_uuid"] == "uuid-abc"


# =========================================================================
# POST /api/setup/tunnel
# =========================================================================
@pytest.mark.asyncio
async def test_create_tunnel_endpoint_returns_uuid(client, monkeypatch, tmp_config_dir):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    resp = await client.post("/api/setup/tunnel", json={"tunnel_name": "demo"})
    assert resp.status_code == 200
    assert resp.json()["tunnel_uuid"] == "uuid-test"  # 來自 mock_cli


# =========================================================================
# POST /api/setup/apply
# =========================================================================
@pytest.mark.asyncio
async def test_apply_success_builds_validates_dns_restarts(
    client, monkeypatch, tmp_config_dir
):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    payload = {
        "routes": [
            {"hostname": "a.example.com", "service": "http://localhost:8080"}
        ],
        "catch_all_service": "",
    }
    resp = await client.post("/api/setup/apply", json=payload)
    assert resp.status_code == 200
    assert resp.json()["status"] == "applied"
    assert (tmp_config_dir / "config.json").exists()


@pytest.mark.asyncio
async def test_apply_calls_route_dns_per_route(
    client, mock_cli, monkeypatch, tmp_config_dir
):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    payload = {
        "routes": [
            {"hostname": "a.example.com", "service": "http://localhost:8080"},
            {"hostname": "b.example.com", "service": "http://localhost:9090"},
        ]
    }
    resp = await client.post("/api/setup/apply", json=payload)
    assert resp.status_code == 200
    assert mock_cli.route_dns.await_count == 2


@pytest.mark.asyncio
async def test_apply_fails_when_no_tunnel(client, monkeypatch, tmp_config_dir):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    resp = await client.post(
        "/api/setup/apply",
        json={"routes": [{"hostname": "a", "service": "s"}]},
    )
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_apply_fails_when_ingress_invalid(
    client, mock_cli, monkeypatch, tmp_config_dir
):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    mock_cli.ingress_validate.return_value = (False, "duplicated hostname")
    resp = await client.post(
        "/api/setup/apply",
        json={"routes": [{"hostname": "a", "service": "s"}]},
    )
    assert resp.status_code == 422
    assert "duplicated" in resp.json()["detail"]


# =========================================================================
# WS /api/setup/login
# =========================================================================
@pytest.mark.asyncio
async def test_login_ws_streams_url(client):
    from starlette.testclient import TestClient

    from backend.main import app

    with TestClient(app).websocket_connect("/api/setup/login") as ws:
        msg = ws.receive_json()
        assert msg["type"] == "url"
        assert msg["url"].startswith("https://dash.cloudflare.com/argotunnel")


# ── token-mode guard ───────────────────────────────────────
import json as _json


@pytest.mark.asyncio
async def test_create_tunnel_blocked_in_token_mode(client, tmp_config_dir, monkeypatch):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "settings.json").write_text(_json.dumps({"mode": "token"}))
    resp = await client.post("/api/setup/tunnel", json={"tunnel_name": "x"})
    assert resp.status_code == 409
    assert "token" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_apply_blocked_in_token_mode(client, tmp_config_dir, monkeypatch):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "settings.json").write_text(_json.dumps({"mode": "token"}))
    (tmp_config_dir / "tunnel.json").write_text(_json.dumps({"TunnelID": "u"}))
    resp = await client.post("/api/setup/apply", json={"routes": []})
    assert resp.status_code == 409


@pytest.mark.asyncio
async def test_create_tunnel_allowed_in_local_mode(client, tmp_config_dir, monkeypatch):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "settings.json").write_text(_json.dumps({"mode": "local"}))
    resp = await client.post("/api/setup/tunnel", json={"tunnel_name": "demo"})
    assert resp.status_code == 200
    assert resp.json()["tunnel_uuid"] == "uuid-test"
