"""Setup wizard endpoints: state / create tunnel / apply config / login (WS)."""
import json
from pathlib import Path

from fastapi import APIRouter, HTTPException, WebSocket
from pydantic import BaseModel

from ..models.schemas import SetupState, TunnelMode
from ..services import runtime
from ..services.instances import pm, config_mgr, cli, token_store

router = APIRouter(prefix="/api/setup", tags=["setup"])

DATA_DIR = Path("/data")

_TOKEN_MODE_MSG = (
    "上線精靈僅適用於本地管理 (local) 模式;此實例目前為 token 模式,"
    "正由既有 tunnel 提供服務。請改用 Config 頁設定,或先將 mode 切換為 local "
    "再使用精靈,以免誤建 tunnel 或中斷現有連線。"
)


async def _reject_if_token_mode() -> None:
    """Guard: the wizard creates/replaces tunnels and must not run while a
    token-mode tunnel is in service (would create a stray tunnel / disrupt)."""
    cfg = await config_mgr.load()
    if cfg.get("mode") == "token":
        raise HTTPException(409, _TOKEN_MODE_MSG)


@router.get("/state", response_model=SetupState)
async def get_state() -> SetupState:
    cfg = await config_mgr.load()
    has_cert = (DATA_DIR / "cert.pem").exists()
    tunnel_file = DATA_DIR / "tunnel.json"
    has_tunnel = tunnel_file.exists()
    uuid = None
    if has_tunnel:
        try:
            uuid = json.loads(tunnel_file.read_text()).get("TunnelID")
        except Exception:
            uuid = None
    return SetupState(
        has_cert=has_cert,
        has_tunnel=has_tunnel,
        tunnel_uuid=uuid,
        mode=TunnelMode(cfg.get("mode", "local")),
    )


class CreateTunnelReq(BaseModel):
    tunnel_name: str


@router.post("/tunnel")
async def create_tunnel(req: CreateTunnelReq):
    await _reject_if_token_mode()
    cred = str(DATA_DIR / "tunnel.json")
    uuid = await cli.create_tunnel(name=req.tunnel_name, cred_file=cred)
    try:
        runtime.check_credentials(DATA_DIR)
    except runtime.TunnelStartError as exc:
        raise HTTPException(exc.status, exc.message) from exc
    cfg = await config_mgr.load()
    cfg["tunnel_name"] = req.tunnel_name
    await config_mgr.save(cfg)
    return {"tunnel_uuid": uuid}


class ApplyReq(BaseModel):
    routes: list[dict] = []
    catch_all_service: str = ""


@router.post("/apply")
async def apply(req: ApplyReq):
    await _reject_if_token_mode()
    if not (DATA_DIR / "tunnel.json").exists():
        raise HTTPException(400, "尚未建立 tunnel")
    cfg = await config_mgr.load()
    cfg = {**cfg, "routes": req.routes, "catch_all_service": req.catch_all_service}
    try:
        await runtime.apply(pm, config_mgr, token_store, cli, DATA_DIR, new_cfg=cfg)
    except runtime.TunnelStartError as exc:
        raise HTTPException(exc.status, exc.message) from exc
    return {"status": "applied", "route_count": len(req.routes)}


@router.websocket("/login")
async def login_ws(ws: WebSocket):
    await ws.accept()
    cfg = await config_mgr.load()
    if cfg.get("mode") == "token":
        await ws.send_json({"type": "error", "message": _TOKEN_MODE_MSG})
        await ws.close()
        return
    src = "/root/.cloudflared/cert.pem"
    dest = str(DATA_DIR / "cert.pem")
    try:
        async for url in cli.login(src_cert=src, dest_cert=dest):
            await ws.send_json({"type": "url", "url": url})
        try:
            runtime.check_credentials(DATA_DIR)
        except runtime.TunnelStartError as exc:
            await ws.send_json({"type": "error", "message": exc.message})
            return
        await ws.send_json({"type": "done"})
    finally:
        await ws.close()
