"""Guided WOOW PaaS account and Security Access connection.

Same flow and PaaS API as the HA add-on (Woow_ha_cloudflare_tunnel_webgui
1.1.x): OAuth device authorization, per-route Access review, tunnel binding,
anonymous external checks and release. Only this backend handles OAuth tokens
or the tunnel credential; the browser gets navigation URLs and non-secret
summaries.

What differs from the add-on is how the credential is applied. The add-on
writes it into its Supervisor options and restarts itself, so a release has to
wait for the restart. Here the token goes to the 0600 token file and this
process restarts its own cloudflared child; on disconnect the child is stopped
and confirmed gone (process exited, metrics port closed) before the remote
binding is released, in the same request.
"""
from __future__ import annotations

import asyncio
import json
import os
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlencode, urlparse

import aiohttp
from fastapi import APIRouter, HTTPException, Query

from ..services import metrics, runtime
from ..services.external_probe import probe as probe_hostname
from ..services.instances import cli, config_mgr, pm, token_store

router = APIRouter(prefix="/api/paas", tags=["paas"])

DATA_DIR = Path("/data")
PAAS_BASE_URL = "https://aiot.woowtech.io"
CLIENT_ID = os.environ.get("PAAS_CLIENT_ID", "woow-ha-smart-home")
INSTANCE_LABEL = "Woow Cloudflared (Podman)"
SCOPES = "workspace:read security-access:read security-access:tunnel"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
_pending: dict = {}
# Serializes claim, disconnect and configuration writes (routers/config.py),
# so a concurrent save cannot reintroduce a credential during a release.
lock = asyncio.Lock()


def _api_base() -> str:
    # Override is for isolated contract tests and staging. The shipped image
    # uses the fixed production origin, never a browser-provided URL.
    return os.environ.get("PAAS_API_BASE", PAAS_BASE_URL).rstrip("/")


def _portal_path(workspace_id: int, access_id: int | None = None, tab: str = "overview") -> str:
    if access_id is None:
        return f"{PAAS_BASE_URL}/woow#/workspace/{workspace_id}"
    if tab not in ("overview", "application", "access"):
        raise ValueError("Unsupported PaaS tab")
    return f"{PAAS_BASE_URL}/woow#/workspace/{workspace_id}/security-access/{access_id}/{tab}"


async def _form_post(path: str, form: dict) -> tuple[int, dict]:
    try:
        timeout = aiohttp.ClientTimeout(total=15)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(f"{_api_base()}{path}", data=form) as response:
                payload = await response.json(content_type=None)
                return response.status, payload if isinstance(payload, dict) else {}
    except (aiohttp.ClientError, TimeoutError, ValueError) as exc:
        raise HTTPException(502, "PaaS 暫時無法連線，請稍後重試") from exc


async def _access_token() -> str:
    state = _state()
    token = state.get("access_token")
    if token and state.get("expires_at", 0) > time.time() + 60:
        return token
    refresh = state.get("refresh_token")
    if not refresh:
        raise HTTPException(401, "請先連接 PaaS 帳戶")
    status, payload = await _form_post(
        "/oauth2/token",
        {"grant_type": "refresh_token", "refresh_token": refresh, "client_id": CLIENT_ID},
    )
    if status != 200 or not payload.get("access_token"):
        raise HTTPException(401, "PaaS 授權已失效，請重新授權")
    state.update(
        access_token=payload["access_token"],
        refresh_token=payload.get("refresh_token") or refresh,
        expires_at=time.time() + max(30, int(payload.get("expires_in") or 3600)),
    )
    _save_state(state)
    return state["access_token"]


async def _request(method: str, path: str) -> dict:
    token = await _access_token()
    try:
        timeout = aiohttp.ClientTimeout(total=15)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.request(
                method, f"{_api_base()}{path}", headers={"Authorization": f"Bearer {token}"}
            ) as response:
                payload = await response.json(content_type=None)
                if response.status == 401:
                    raise HTTPException(401, "PaaS 授權已失效，請重新授權")
                if response.status == 403:
                    raise HTTPException(403, "需要此工作區的管理權限，請到 PaaS 確認身分")
                if response.status == 409:
                    raise HTTPException(409, "這個服務已綁定其他裝置，請先在 PaaS 解除綁定")
                if response.status >= 400 or not isinstance(payload, dict):
                    raise HTTPException(502, "PaaS 暫時無法讀取服務，請稍後重試")
                return payload
    except (aiohttp.ClientError, TimeoutError, ValueError) as exc:
        raise HTTPException(502, "PaaS 暫時無法連線，請稍後重試") from exc


def _state_path() -> Path:
    return Path(os.environ.get("PAAS_LINK_STATE", str(DATA_DIR / "paas-link.json")))


def _state() -> dict:
    try:
        return json.loads(_state_path().read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _save_state(value: dict) -> None:
    target = _state_path()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, temporary = tempfile.mkstemp(prefix=".paas-link-", dir=target.parent)
    try:
        with os.fdopen(handle, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def managed_by_paas() -> bool:
    state = _state()
    return bool(state.get("connection") or state.get("release_pending"))


@router.get("/bootstrap")
async def bootstrap() -> dict:
    state = _state()
    return {
        "authorized": bool(state.get("refresh_token")),
        "portal_url": f"{PAAS_BASE_URL}/woow#/workspaces",
        "connection": state.get("connection"),
        "release_pending": bool(state.get("release_pending")),
    }


@router.post("/authorization")
async def start_authorization() -> dict:
    status, payload = await _form_post(
        "/oauth2/device_authorization", {"client_id": CLIENT_ID, "scope": SCOPES}
    )
    if status != 200:
        raise HTTPException(502, "PaaS 無法開始授權，請稍後重試")
    device_code = payload.get("device_code")
    user_code = payload.get("user_code")
    verification_url = payload.get("verification_uri_complete") or payload.get("verification_uri")
    api_origin = urlparse(_api_base())
    verify_origin = urlparse(verification_url or "")
    if not (
        isinstance(device_code, str) and device_code
        and isinstance(user_code, str) and user_code
        and verify_origin.scheme == api_origin.scheme
        and verify_origin.netloc == api_origin.netloc
        and verify_origin.path == "/device"
    ):
        raise HTTPException(502, "PaaS 授權回應格式不正確")
    interval = max(5, int(payload.get("interval") or 5))
    expires_in = min(900, max(30, int(payload.get("expires_in") or 900)))
    _pending.clear()
    _pending.update(
        device_code=device_code,
        interval=interval,
        next_poll=time.monotonic() + interval,
        expires=time.monotonic() + expires_in,
    )
    return {
        "user_code": user_code,
        "verification_url": verification_url,
        "expires_in": expires_in,
        "interval": interval,
    }


@router.get("/authorization/status")
async def authorization_status() -> dict:
    if not _pending:
        return {"status": "authorized" if _state().get("refresh_token") else "idle"}
    now = time.monotonic()
    if now >= _pending["expires"]:
        _pending.clear()
        return {"status": "expired"}
    if now < _pending["next_poll"]:
        return {"status": "waiting"}
    _pending["next_poll"] = now + _pending["interval"]
    status, payload = await _form_post(
        "/oauth2/token",
        {"grant_type": DEVICE_GRANT, "device_code": _pending["device_code"], "client_id": CLIENT_ID},
    )
    if status != 200:
        error = payload.get("error")
        if error == "slow_down":
            _pending["interval"] += 5
            _pending["next_poll"] = now + _pending["interval"]
            return {"status": "waiting", "interval": _pending["interval"]}
        if error == "authorization_pending":
            return {"status": "waiting", "interval": _pending["interval"]}
        _pending.clear()
        return {"status": "denied" if error == "access_denied" else "expired"}
    access_token = payload.get("access_token")
    refresh_token = payload.get("refresh_token")
    if not isinstance(access_token, str) or not access_token or not isinstance(refresh_token, str) or not refresh_token:
        _pending.clear()
        raise HTTPException(502, "PaaS 授權結果不完整，請重新授權")
    state = _state()
    state.update(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_at=time.time() + max(30, int(payload.get("expires_in") or 3600)),
    )
    _save_state(state)
    _pending.clear()
    return {"status": "authorized"}


@router.post("/authorization/revoke")
async def revoke_authorization() -> dict:
    state = _state()
    if state.get("connection") or state.get("release_pending"):
        raise HTTPException(409, "請先停止本機連線並完成遠端解除綁定")
    refresh_token = state.get("refresh_token")
    if refresh_token:
        status, _ = await _form_post(
            "/oauth2/revoke", {"token": refresh_token, "client_id": CLIENT_ID}
        )
        if status != 200:
            raise HTTPException(502, "PaaS 尚未確認撤銷授權，請稍後重試")
    for key in ("access_token", "refresh_token", "expires_at"):
        state.pop(key, None)
    _pending.clear()
    _save_state(state)
    return {"revoked": True}


@router.get("/workspaces")
async def workspaces() -> dict:
    data = await _request("GET", "/api/security-access/workspaces")
    return {"workspaces": [
        {"id": item["id"], "name": item["name"], "portal_url": _portal_path(item["id"])}
        for item in data.get("workspaces", [])
    ]}


@router.get("/workspaces/{workspace_id}/accesses")
async def accesses(workspace_id: int) -> dict:
    data = await _request("GET", f"/api/security-access/workspaces/{workspace_id}/accesses")
    return {"accesses": [
        {"id": item["id"], "name": item["name"], "state": item["state"],
         "plan_name": item.get("plan_name"), "portal_url": _portal_path(workspace_id, item["id"])}
        for item in data.get("accesses", [])
    ]}


def _review(access: dict) -> dict:
    issues: list[str] = []
    if access.get("state") != "active":
        issues.append("服務尚未啟用或已停權，請到 PaaS 檢查訂閱")
    subscription = access.get("subscription")
    if not isinstance(subscription, dict) or subscription.get("state") != "in_progress":
        issues.append("訂閱無效，請到 PaaS 開通或續訂")
    if isinstance(subscription, dict) and subscription.get("ac_max_access_seats") == 0:
        issues.append("此方案尚未加購 Access 席次；請到 PaaS 方案設定選擇至少 1 席，再加入允許登入的 Email")
    if not access.get("tunnel_id"):
        issues.append("Tunnel 尚未建立，請到 PaaS 完成部署")
    connection = _state().get("connection") or {}
    if access.get("binding_state") != "unbound" and connection.get("access_id") != access.get("id"):
        issues.append("服務已綁定其他裝置，請先到 PaaS 解除綁定")
    if access.get("binding_conflict") or (access.get("connector_count") or 0) > 1:
        issues.append("偵測到多台 connector，請先處理換機衝突")
    routes = access.get("routes")
    if not isinstance(routes, list) or not routes:
        issues.append("尚未建立公開網址，請到 PaaS 新增路由")
        routes = []
    safe_routes = []
    for route in routes:
        host = route.get("hostname") or "未命名路由"
        policies = route.get("access_policies")
        allow = isinstance(policies, list) and any(
            p.get("decision") == "allow" and any(
                rule.get("rule_type") in ("email_list", "email_domain") and rule.get("rule_value")
                for rule in p.get("include", []))
            for p in policies
        )
        broad_access = not isinstance(policies, list) or any(
            p.get("decision") == "bypass" or (
                p.get("decision") == "allow" and any(
                    rule.get("rule_type") in ("everyone", "ip_range", "country")
                    for rule in p.get("include", [])
                )
            ) for p in (policies if isinstance(policies, list) else [])
        )
        login_ready = route.get("login_google") is True or route.get("login_email_otp") is True
        if not login_ready:
            issues.append(f"{host}：尚未指定登入方式；請在 PaaS 勾選 Email OTP 或 Google")
        protected = (
            bool(route.get("hostname")) and bool(route.get("service_url"))
            and route.get("is_protected") is True
            and route.get("access_configuration_ready") is True
            and route.get("access_protection_lost") is False
            and route.get("access_publish_pending") is False
            and not route.get("access_unresolved_idp_types")
            and login_ready
            and allow
            and not broad_access
        )
        if not protected:
            issues.append(f"{host}：Access 保護或允許名單尚未確認，請到 PaaS 設定")
        safe_routes.append({"hostname": route.get("hostname"), "service_url": route.get("service_url"), "protected": protected})
    workspace_id = access.get("workspace_id")
    access_id = access.get("id")
    summary = {
        "id": access_id, "workspace_id": workspace_id, "name": access.get("name"), "state": access.get("state"),
        "subscription": {key: subscription.get(key) for key in (
            "state", "plan_name", "ac_max_access_seats", "ac_used_access_seats",
        )} if isinstance(subscription, dict) else None,
        "binding_state": access.get("binding_state"), "bound_instance_label": access.get("bound_instance_label"),
        "connector_count": access.get("connector_count"), "routes": safe_routes,
    }
    return {
        "ready": not issues,
        "issues": issues,
        "access": summary,
        "portal_access_url": _portal_path(workspace_id, access_id, "access"),
        "portal_routes_url": _portal_path(workspace_id, access_id, "application"),
    }


@router.get("/accesses/{access_id}/review")
async def review_access(access_id: int) -> dict:
    data = await _request("GET", f"/api/security-access/accesses/{access_id}")
    access = data.get("access")
    if not isinstance(access, dict) or access.get("id") != access_id:
        raise HTTPException(502, "PaaS 服務資料格式不正確")
    return _review(access)


@router.get("/connection/status")
async def connection_status(probe: bool = Query(default=False)) -> dict:
    connection = _state().get("connection")
    if not connection:
        return {"connected": False}
    access_id = connection["access_id"]
    data = await _request("GET", f"/api/security-access/accesses/{access_id}/status")
    access = data.get("access")
    if not isinstance(access, dict) or access.get("id") != access_id:
        raise HTTPException(502, "PaaS 連線狀態格式不正確")
    reviewed = _review(access)
    tunnel = await metrics.tunnel_status()
    external = []
    if probe:
        external = await asyncio.gather(*(
            probe_hostname(route["hostname"])
            for route in reviewed["access"]["routes"]
        ))
    return {
        "connected": True,
        "subscription": reviewed["access"]["subscription"],
        "access_ready": reviewed["ready"],
        "issues": reviewed["issues"],
        "routes": reviewed["access"]["routes"],
        "tunnel_status": tunnel.status,
        "connector_count": access.get("connector_count"),
        "binding_conflict": bool(access.get("binding_conflict")),
        "checked_at": time.time(),
        "external_status": "checked" if probe else "not_checked",
        "external": external,
    }


def _release_path(access_id: int, instance_uid: str) -> str:
    query = urlencode({"instance_uid": instance_uid})
    return f"/api/security-access/accesses/{access_id}/tunnel-binding?{query}"


@router.post("/accesses/{access_id}/connect")
async def connect_access(access_id: int) -> dict:
    async with lock:
        review = await review_access(access_id)
        if not review["ready"]:
            raise HTTPException(409, "；".join(review["issues"]))
        state = _state()
        if state.get("release_pending"):
            raise HTTPException(409, "先完成上一個服務的解除綁定，再重新連結")
        prior = state.get("connection") or {}
        if prior and prior.get("access_id") != access_id:
            raise HTTPException(409, "請先解除目前連結，再選擇其他服務")
        if token_store.has() and not prior:
            raise HTTPException(409, "目前已有手動設定的 Tunnel token；請先在設定頁確認並移除")

        instance_uid = state.get("instance_uid") or str(uuid.uuid4())
        state["instance_uid"] = instance_uid
        _save_state(state)  # Persist before claim; retries must reuse the UID.
        query = urlencode({"instance_uid": instance_uid, "instance_label": INSTANCE_LABEL})
        credential = await _request(
            "GET", f"/api/security-access/accesses/{access_id}/tunnel-token?{query}"
        )
        tunnel_token = credential.get("tunnel_token")
        if not isinstance(tunnel_token, str) or not tunnel_token:
            if not prior:
                await _release_after_failed_connect(access_id, instance_uid)
            raise HTTPException(502, "PaaS 未提供有效 Tunnel 憑證；請檢查是否仍有待解除的綁定")

        previous_cfg = await config_mgr.load()
        try:
            token_store.set(tunnel_token)
            await config_mgr.save({**previous_cfg, "mode": "token"})
            state["connection"] = {
                "access_id": access_id,
                "workspace_id": review["access"]["workspace_id"],
                "name": review["access"]["name"],
                "tunnel_id": credential.get("tunnel_id"),
            }
            _save_state(state)
            await runtime.apply(pm, config_mgr, token_store, cli, DATA_DIR)
        except (OSError, runtime.TunnelStartError) as exc:
            detail = exc.message if isinstance(exc, runtime.TunnelStartError) else "設定寫入失敗"
            if prior:
                # A reconnect of the same service: keep the existing binding
                # and its record rather than orphaning the remote claim.
                raise HTTPException(502, f"無法重新啟用 PaaS Tunnel：{detail}；原有綁定保留") from exc
            # Undo locally first: the token must not stay installed unbound.
            await pm.stop()
            token_store.clear()
            await config_mgr.save(previous_cfg)
            state.pop("connection", None)
            _save_state(state)
            await _release_after_failed_connect(access_id, instance_uid)
            raise HTTPException(502, f"無法啟用 PaaS Tunnel：{detail}；已回復本機設定") from exc
        return {"connected": True, "restarting": False, "connection": state["connection"]}


async def _release_after_failed_connect(access_id: int, instance_uid: str) -> None:
    try:
        await _request("DELETE", _release_path(access_id, instance_uid))
    except HTTPException:
        # The user must see a warning if remote release cannot be confirmed.
        state = _state()
        state["release_pending"] = True
        state["pending_release_access_id"] = access_id
        _save_state(state)


async def _tunnel_confirmed_down() -> bool:
    return not pm.is_running() and not (await metrics.tunnel_status()).metrics_reachable


async def _release() -> dict:
    """Release the remote binding once the local connector is provably gone."""
    state = _state()
    connection = state.get("connection") or {}
    if not state.get("release_pending"):
        return {"released": True}
    access_id = state.get("pending_release_access_id") or connection.get("access_id")
    if not access_id:
        raise HTTPException(409, "缺少解除綁定目標；請到 PaaS Portal 人工確認")
    if token_store.has():
        raise HTTPException(409, "本機 Tunnel token 仍在設定中；先停止本機連線")
    if not await _tunnel_confirmed_down():
        raise HTTPException(409, "Tunnel 程序仍在執行，暫不解除遠端綁定")
    instance_uid = state.get("instance_uid")
    if not instance_uid:
        raise HTTPException(409, "缺少原始裝置 ID；請在 PaaS Portal 解除綁定")
    await _request("DELETE", _release_path(access_id, instance_uid))
    for key in ("connection", "release_pending", "pending_release_access_id"):
        state.pop(key, None)
    _save_state(state)
    return {"released": True}


@router.post("/disconnect")
async def disconnect() -> dict:
    async with lock:
        state = _state()
        if not state.get("connection"):
            raise HTTPException(409, "目前沒有 PaaS 連結")
        state["release_pending"] = True
        _save_state(state)
        try:
            await runtime.stop(pm)
            token_store.clear()
            # Clear the local routes as the add-on does, so the next start
            # cannot bring up a different, unintended public Local tunnel.
            cfg = await config_mgr.load()
            await config_mgr.save({**cfg, "mode": "local", "routes": [], "catch_all_service": ""})
            (DATA_DIR / "config.json").unlink(missing_ok=True)
        except OSError as exc:
            raise HTTPException(502, "無法停止本機 Tunnel；遠端綁定仍保留，請重試") from exc
        try:
            await _release()
        except HTTPException:
            # Local side is stopped; the UI offers /disconnect/finish to retry.
            return {"stopped": True, "release_pending": True}
        return {"stopped": True, "release_pending": False}


@router.post("/disconnect/finish")
async def finish_disconnect() -> dict:
    async with lock:
        return await _release()


async def reconcile_pending_disconnect() -> None:
    """Retry an unconfirmed release when the app starts."""
    if not _state().get("release_pending"):
        return
    try:
        async with lock:
            await _release()
    except HTTPException:
        # Keep release_pending on disk so the UI can offer a retry.
        pass
