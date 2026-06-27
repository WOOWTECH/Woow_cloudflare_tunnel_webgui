"""Setup wizard endpoints: state / create tunnel / apply config / login (WS)."""
import json
from pathlib import Path

from fastapi import APIRouter, HTTPException, WebSocket
from pydantic import BaseModel

from ..models.schemas import SetupState, TunnelMode
from ..services.config_builder import build_ingress_config, write_config_json
from ..services.process_manager import build_run_args
from ..services.instances import pm, config_mgr, cli

router = APIRouter(prefix="/api/setup", tags=["setup"])

DATA_DIR = Path("/data")


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
    cred = str(DATA_DIR / "tunnel.json")
    uuid = await cli.create_tunnel(name=req.tunnel_name, cred_file=cred)
    cfg = await config_mgr.load()
    cfg["tunnel_name"] = req.tunnel_name
    await config_mgr.save(cfg)
    return {"tunnel_uuid": uuid}


class ApplyReq(BaseModel):
    routes: list[dict] = []
    catch_all_service: str = ""


@router.post("/apply")
async def apply(req: ApplyReq):
    tunnel_file = DATA_DIR / "tunnel.json"
    if not tunnel_file.exists():
        raise HTTPException(400, "尚未建立 tunnel")
    uuid = json.loads(tunnel_file.read_text())["TunnelID"]

    cfg = await config_mgr.load()
    config = build_ingress_config(
        tunnel_uuid=uuid,
        credentials_file=str(tunnel_file),
        routes=req.routes,
        catch_all_service=req.catch_all_service or None,
        no_tls_verify=cfg.get("no_tls_verify", True),
    )
    config_path = DATA_DIR / "config.json"
    write_config_json(config, config_path)

    ok, output = await cli.ingress_validate(str(config_path))
    if not ok:
        raise HTTPException(422, f"ingress 驗證失敗:{output}")

    for r in req.routes:
        await cli.route_dns(uuid, r["hostname"])

    cfg["routes"] = req.routes
    cfg["catch_all_service"] = req.catch_all_service
    await config_mgr.save(cfg)

    args = build_run_args(
        mode="local",
        origincert=str(DATA_DIR / "cert.pem"),
        config=str(config_path),
        tunnel_name=cfg.get("tunnel_name", ""),
        post_quantum=cfg.get("post_quantum", False),
        log_level=cfg.get("log_level", "info"),
    )
    if pm.is_running():
        await pm.restart()
    else:
        await pm.start(args)
    return {"status": "applied", "route_count": len(req.routes)}


@router.websocket("/login")
async def login_ws(ws: WebSocket):
    await ws.accept()
    src = "/root/.cloudflared/cert.pem"
    dest = str(DATA_DIR / "cert.pem")
    try:
        async for url in cli.login(src_cert=src, dest_cert=dest):
            await ws.send_json({"type": "url", "url": url})
        await ws.send_json({"type": "done"})
    finally:
        await ws.close()
