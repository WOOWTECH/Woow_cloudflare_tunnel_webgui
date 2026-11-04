"""
測試: WOOW PaaS 連結(與 HA add-on 1.1.x 相同的 PaaS API 契約)
涵蓋: device 授權、服務審查擋下不安全設定、綁定後寫入 0600 token 並以 token 模式啟動、
連線失敗回滾並釋放綁定、解除綁定先確認本機 connector 已停止、設定頁不能動 PaaS 管理的 token
"""

import asyncio
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from urllib.parse import parse_qs, unquote_plus

import pytest


@pytest.fixture()
def fake_paas(monkeypatch):
    class Requests(list):
        fail_release = False
        fail_claim = False
        device_error = None
        detail = {
            "id": 25,
            "workspace_id": 7,
            "name": "家用主機",
            "state": "active",
            "tunnel_id": "tunnel-25",
            "binding_state": "unbound",
            "binding_conflict": False,
            "connector_count": 0,
            "subscription": {"state": "in_progress", "plan_name": "1 route"},
            "routes": [{
                "hostname": "ha.example.com",
                "service_url": "http://localhost:8123",
                "is_protected": True,
                "access_configuration_ready": True,
                "access_protection_lost": False,
                "access_publish_pending": False,
                "access_unresolved_idp_types": "",
                "login_email_otp": True,
                "login_google": False,
                "access_policies": [{"decision": "allow", "include": [
                    {"rule_type": "email_list", "rule_value": "alice@example.com"}]}],
            }],
        }

    received = Requests()

    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = parse_qs(self.rfile.read(length).decode())
            received.append((self.path, body))
            port = self.server.server_port
            if self.path == "/oauth2/device_authorization":
                self._send(200, {
                    "device_code": "PRIVATE_DEVICE_CODE",
                    "user_code": "ABCD-EFGH",
                    "verification_uri": f"http://127.0.0.1:{port}/device",
                    "verification_uri_complete": f"http://127.0.0.1:{port}/device?user_code=ABCD-EFGH",
                    "expires_in": 900,
                    "interval": 1,
                })
            elif self.path == "/oauth2/token":
                if received.device_error:
                    self._send(400, {"error": received.device_error})
                else:
                    self._send(200, {"access_token": "PRIVATE_ACCESS_TOKEN",
                                     "refresh_token": "PRIVATE_REFRESH_TOKEN",
                                     "expires_in": 3600, "token_type": "Bearer"})
            elif self.path == "/oauth2/revoke":
                self._send(200, {})
            else:
                self._send(404, {"error": "unknown_path"})

        def do_GET(self):
            received.append((self.path, self.headers.get("Authorization", "")))
            if self.path == "/api/security-access/workspaces":
                self._send(200, {"workspaces": [{"id": 7, "name": "家用工作區"}]})
            elif self.path == "/api/security-access/workspaces/7/accesses":
                self._send(200, {"accesses": [{"id": 25, "name": "家用主機", "state": "active"}]})
            elif self.path in ("/api/security-access/accesses/25",
                               "/api/security-access/accesses/25/status"):
                self._send(200, {"access": received.detail})
            elif self.path.startswith("/api/security-access/accesses/25/tunnel-token?"):
                if received.fail_claim:
                    self._send(409, {"error": "already_bound"})
                else:
                    self._send(200, {"tunnel_token": "PRIVATE_TUNNEL_TOKEN", "tunnel_id": "tunnel-25"})
            else:
                self._send(404, {"error": "Not Found"})

        def do_DELETE(self):
            received.append((self.path, self.headers.get("Authorization", "")))
            if received.fail_release:
                self._send(503, {"error": "temporary"})
            else:
                self._send(200, {"binding_state": "unbound"})

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setenv("PAAS_API_BASE", f"http://127.0.0.1:{server.server_port}")
    yield received
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)


def _authorized(data_dir, **extra):
    state = {"access_token": "PRIVATE_ACCESS_TOKEN", "refresh_token": "PRIVATE_REFRESH_TOKEN",
             "expires_at": time.time() + 3600, **extra}
    (data_dir / "paas-link.json").write_text(json.dumps(state))


def _link(data_dir):
    return json.loads((data_dir / "paas-link.json").read_text())


@pytest.fixture()
def stoppable_pm(mock_pm):
    """mock_pm whose stop() really ends the 'process'."""
    async def _stop(*_args, **_kwargs):
        mock_pm.is_running.return_value = False
    mock_pm.stop.side_effect = _stop
    return mock_pm


@pytest.mark.asyncio
async def test_unlinked_offers_real_portal_entry(client):
    response = await client.get("/api/paas/bootstrap")
    assert response.status_code == 200
    assert response.json() == {
        "authorized": False,
        "portal_url": "https://aiot.woowtech.io/woow#/workspaces",
        "connection": None,
        "release_pending": False,
    }


@pytest.mark.asyncio
async def test_device_authorization_hides_device_code_and_requests_only_sa_scopes(client, fake_paas):
    response = await client.post("/api/paas/authorization")
    assert response.status_code == 200
    body = response.json()
    assert body["user_code"] == "ABCD-EFGH"
    assert body["verification_url"].endswith("/device?user_code=ABCD-EFGH")
    assert "PRIVATE_DEVICE_CODE" not in str(body)
    assert fake_paas[0][0] == "/oauth2/device_authorization"
    assert fake_paas[0][1]["scope"] == ["workspace:read security-access:read security-access:tunnel"]


@pytest.mark.asyncio
async def test_device_poll_respects_interval_and_persists_tokens_privately(
        client, fake_paas, tmp_config_dir):
    assert (await client.post("/api/paas/authorization")).status_code == 200
    early = await client.get("/api/paas/authorization/status")
    assert early.json()["status"] == "waiting"
    assert len(fake_paas) == 1  # No early token request.
    await asyncio.sleep(5.1)
    done = await client.get("/api/paas/authorization/status")
    assert done.json() == {"status": "authorized"}
    assert "PRIVATE_ACCESS_TOKEN" not in done.text
    link_file = tmp_config_dir / "paas-link.json"
    assert link_file.stat().st_mode & 0o777 == 0o600
    assert _link(tmp_config_dir)["refresh_token"] == "PRIVATE_REFRESH_TOKEN"
    assert "device_code" not in link_file.read_text()


@pytest.mark.asyncio
async def test_subscription_list_and_review_are_read_only(client, fake_paas, tmp_config_dir):
    _authorized(tmp_config_dir)
    assert (await client.get("/api/paas/workspaces")).json()["workspaces"][0]["id"] == 7
    assert (await client.get("/api/paas/workspaces/7/accesses")).json()["accesses"][0]["id"] == 25
    review = (await client.get("/api/paas/accesses/25/review")).json()
    assert review["ready"] is True
    assert review["access"]["routes"][0]["hostname"] == "ha.example.com"
    assert all("tunnel-token" not in path for path, _ in fake_paas)


@pytest.mark.asyncio
async def test_protected_service_claims_and_starts_in_token_mode(
        client, fake_paas, stoppable_pm, tmp_config_dir):
    _authorized(tmp_config_dir)
    response = await client.post("/api/paas/accesses/25/connect")
    assert response.status_code == 200
    assert response.json()["connected"] is True
    assert "PRIVATE_TUNNEL_TOKEN" not in response.text
    token_file = tmp_config_dir / ".tunnel_token"
    assert token_file.read_text() == "PRIVATE_TUNNEL_TOKEN"
    assert token_file.stat().st_mode & 0o777 == 0o600
    assert (await client.get("/api/config")).json()["mode"] == "token"
    args = stoppable_pm.start.await_args.args[0]
    assert args[-2:] == ["--token-file", str(token_file)]
    assert not any("PRIVATE_TUNNEL_TOKEN" in a for a in args)
    assert any("instance_label=Woow Cloudflared (Podman)" in unquote_plus(path) for path, _ in fake_paas)
    state = _link(tmp_config_dir)
    assert state["connection"]["access_id"] == 25 and state["instance_uid"]
    assert "PRIVATE_TUNNEL_TOKEN" not in (tmp_config_dir / "paas-link.json").read_text()


@pytest.mark.asyncio
async def test_manual_token_blocks_paas_claim(client, fake_paas, tmp_config_dir):
    _authorized(tmp_config_dir)
    (tmp_config_dir / ".tunnel_token").write_text("manual")
    response = await client.post("/api/paas/accesses/25/connect")
    assert response.status_code == 409
    assert "手動" in response.json()["detail"]
    assert all("tunnel-token" not in path for path, _ in fake_paas)


@pytest.mark.asyncio
async def test_config_cannot_touch_the_managed_token_or_leave_token_mode(
        client, fake_paas, stoppable_pm, tmp_config_dir):
    _authorized(tmp_config_dir)
    assert (await client.post("/api/paas/accesses/25/connect")).status_code == 200
    stoppable_pm.start.reset_mock()
    assert (await client.get("/api/config")).json()["tunnel_token_managed_by_paas"] is True
    removed = await client.put("/api/config?restart=true", json={"mode": "token", "tunnel_token": ""})
    assert removed.status_code == 409 and "解除綁定" in removed.json()["detail"]
    to_local = await client.put("/api/config", json={"mode": "local"})
    assert to_local.status_code == 409
    assert (tmp_config_dir / ".tunnel_token").read_text() == "PRIVATE_TUNNEL_TOKEN"
    stoppable_pm.start.assert_not_awaited()
    # Unrelated settings still save without resending the credential.
    ok = await client.put("/api/config", json={"mode": "token", "log_level": "debug"})
    assert ok.status_code == 200
    assert (tmp_config_dir / ".tunnel_token").read_text() == "PRIVATE_TUNNEL_TOKEN"


@pytest.mark.asyncio
async def test_config_is_locked_during_pending_release(client, tmp_config_dir, mock_pm):
    (tmp_config_dir / "paas-link.json").write_text(json.dumps({"release_pending": True}))
    response = await client.put("/api/config?restart=true", json={"mode": "local"})
    assert response.status_code == 409
    mock_pm.start.assert_not_awaited()


@pytest.mark.asyncio
async def test_failed_start_rolls_back_and_releases_the_new_binding(
        client, fake_paas, stoppable_pm, tmp_config_dir):
    _authorized(tmp_config_dir)
    # A credential file that cannot be made private stops the start.
    (tmp_config_dir / "elsewhere").write_text("x")
    (tmp_config_dir / "cert.pem").symlink_to(tmp_config_dir / "elsewhere")
    response = await client.post("/api/paas/accesses/25/connect")
    assert response.status_code == 502
    assert "已回復本機設定" in response.json()["detail"]
    assert not (tmp_config_dir / ".tunnel_token").exists()
    assert (await client.get("/api/config")).json()["mode"] == "local"
    assert any("/tunnel-binding?instance_uid=" in path for path, _ in fake_paas)
    assert _link(tmp_config_dir).get("connection") is None


@pytest.mark.asyncio
async def test_failed_release_after_failed_start_can_be_retried(
        client, fake_paas, stoppable_pm, tmp_config_dir):
    _authorized(tmp_config_dir)
    fake_paas.fail_release = True
    (tmp_config_dir / "elsewhere").write_text("x")
    (tmp_config_dir / "cert.pem").symlink_to(tmp_config_dir / "elsewhere")
    assert (await client.post("/api/paas/accesses/25/connect")).status_code == 502
    state = _link(tmp_config_dir)
    assert state["release_pending"] is True and state["pending_release_access_id"] == 25
    stoppable_pm.is_running.return_value = False
    fake_paas.fail_release = False
    assert (await client.post("/api/paas/disconnect/finish")).json() == {"released": True}
    assert _link(tmp_config_dir).get("release_pending") is None


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["unprotected", "everyone", "draft", "no_login", "zero_seats"])
async def test_unsafe_service_blocks_connect_without_claiming(client, fake_paas, tmp_config_dir, change):
    _authorized(tmp_config_dir)
    route = fake_paas.detail["routes"][0]
    if change == "unprotected":
        route["is_protected"] = False
    elif change == "everyone":
        route["access_policies"].append({"decision": "allow", "include": [{"rule_type": "everyone"}]})
    elif change == "draft":
        fake_paas.detail["subscription"]["state"] = "draft"
    elif change == "no_login":
        route.update(login_email_otp=False, login_google=False)
    else:
        fake_paas.detail["subscription"].update(ac_max_access_seats=0, ac_used_access_seats=0)
    assert (await client.get("/api/paas/accesses/25/review")).json()["ready"] is False
    assert (await client.post("/api/paas/accesses/25/connect")).status_code == 409
    assert all("tunnel-token" not in path for path, _ in fake_paas)


@pytest.mark.asyncio
async def test_binding_conflict_never_installs_a_token(client, fake_paas, tmp_config_dir, mock_pm):
    _authorized(tmp_config_dir)
    fake_paas.fail_claim = True
    response = await client.post("/api/paas/accesses/25/connect")
    assert response.status_code == 409
    assert not (tmp_config_dir / ".tunnel_token").exists()
    mock_pm.start.assert_not_awaited()


@pytest.mark.asyncio
async def test_disconnect_stops_clears_and_releases_in_one_request(
        client, fake_paas, stoppable_pm, tmp_config_dir):
    _authorized(tmp_config_dir)
    assert (await client.post("/api/paas/accesses/25/connect")).status_code == 200
    (tmp_config_dir / "config.json").write_text("{}")
    response = await client.post("/api/paas/disconnect")
    assert response.status_code == 200
    assert response.json() == {"stopped": True, "release_pending": False}
    stoppable_pm.stop.assert_awaited()
    assert not (tmp_config_dir / ".tunnel_token").exists()
    assert not (tmp_config_dir / "config.json").exists()
    cfg = (await client.get("/api/config")).json()
    assert cfg["mode"] == "local" and cfg["routes"] == []
    uid = _link(tmp_config_dir)["instance_uid"]
    assert any(f"tunnel-binding?instance_uid={uid}" in path for path, _ in fake_paas)
    assert _link(tmp_config_dir).get("connection") is None


@pytest.mark.asyncio
async def test_release_waits_while_the_connector_still_answers(
        client, fake_paas, mock_pm, tunnel_status, tmp_config_dir):
    _authorized(tmp_config_dir, instance_uid="host-1",
                connection={"access_id": 25, "workspace_id": 7, "name": "家用主機"})
    # stop() returned but the process is still up and /ready still answers.
    tunnel_status.metrics_reachable = True
    response = await client.post("/api/paas/disconnect")
    assert response.json() == {"stopped": True, "release_pending": True}
    assert all("tunnel-binding" not in path for path, _ in fake_paas)
    assert (await client.post("/api/paas/disconnect/finish")).status_code == 409
    mock_pm.is_running.return_value = False
    tunnel_status.metrics_reachable = False
    assert (await client.post("/api/paas/disconnect/finish")).json() == {"released": True}
    assert any("tunnel-binding?instance_uid=host-1" in path for path, _ in fake_paas)


@pytest.mark.asyncio
async def test_external_probe_rejects_private_hostname_without_network_call(
        client, fake_paas, tmp_config_dir):
    _authorized(tmp_config_dir, instance_uid="host-1",
                connection={"access_id": 25, "workspace_id": 7, "name": "家用主機"})
    fake_paas.detail["routes"][0]["hostname"] = "127.0.0.1"
    response = await client.get("/api/paas/connection/status?probe=true")
    assert response.status_code == 200
    assert response.json()["external"][0]["status"] == "blocked_private_address"


@pytest.mark.asyncio
async def test_account_revoke_removes_local_credentials_after_platform_ack(
        client, fake_paas, tmp_config_dir):
    _authorized(tmp_config_dir, instance_uid="host-1")
    response = await client.post("/api/paas/authorization/revoke")
    assert response.json() == {"revoked": True}
    assert any(path == "/oauth2/revoke" for path, _ in fake_paas)
    saved = _link(tmp_config_dir)
    assert "refresh_token" not in saved and "access_token" not in saved
    assert saved["instance_uid"] == "host-1"


@pytest.mark.asyncio
async def test_account_cannot_revoke_while_connector_is_bound(client, fake_paas, tmp_config_dir):
    _authorized(tmp_config_dir, connection={"access_id": 25, "workspace_id": 7, "name": "家用主機"})
    assert (await client.post("/api/paas/authorization/revoke")).status_code == 409
    assert not fake_paas


@pytest.mark.asyncio
async def test_device_slow_down_increases_poll_interval(client, fake_paas):
    fake_paas.device_error = "slow_down"
    assert (await client.post("/api/paas/authorization")).status_code == 200
    await asyncio.sleep(5.1)
    result = await client.get("/api/paas/authorization/status")
    assert result.json() == {"status": "waiting", "interval": 10}
    assert (await client.get("/api/paas/authorization/status")).json()["status"] == "waiting"
    assert sum(path == "/oauth2/token" for path, _ in fake_paas) == 1


@pytest.mark.asyncio
async def test_pending_publication_with_complete_protection_does_not_block(client, fake_paas, tmp_config_dir):
    # After an authorization change PaaS keeps the route pending (origin
    # published as http_status:503) until a live connector lets it re-confirm
    # Access. Waiting for pending=False before connecting would never end.
    _authorized(tmp_config_dir)
    fake_paas.detail["routes"][0].update(access_publish_pending=True, access_configuration_ready=False)
    review = (await client.get("/api/paas/accesses/25/review")).json()
    assert review["ready"] is True
    assert review["awaiting_publication"] is True
    route = review["access"]["routes"][0]
    assert route["protected"] is False and route["awaiting_publication"] is True


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["no_login", "everyone", "unprotected", "lost", "unresolved_idp", "no_allow"])
async def test_pending_publication_never_hides_a_missing_protection(client, fake_paas, tmp_config_dir, change):
    _authorized(tmp_config_dir)
    route = fake_paas.detail["routes"][0]
    route.update(access_publish_pending=True, access_configuration_ready=False)
    if change == "no_login":
        route.update(login_email_otp=False, login_google=False)
    elif change == "everyone":
        route["access_policies"].append({"decision": "allow", "include": [{"rule_type": "everyone"}]})
    elif change == "unprotected":
        route["is_protected"] = False
    elif change == "lost":
        route["access_protection_lost"] = True
    elif change == "unresolved_idp":
        route["access_unresolved_idp_types"] = "google"
    else:
        route["access_policies"] = []
    review = (await client.get("/api/paas/accesses/25/review")).json()
    assert review["ready"] is False
    assert review["access"]["routes"][0]["awaiting_publication"] is False
    assert (await client.post("/api/paas/accesses/25/connect")).status_code == 409
    assert all("tunnel-token" not in path for path, _ in fake_paas)
