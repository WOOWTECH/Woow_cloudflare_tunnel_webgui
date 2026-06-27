from fastapi import APIRouter

from ..services.config_manager import ConfigManager
from ..services.process_manager import ProcessManager, build_run_args
from ..services.token_store import TokenStore

router = APIRouter(prefix="/api/tunnel", tags=["tunnel"])
config_mgr = ConfigManager()
pm = ProcessManager()
token_store = TokenStore()


@router.get("/status")
async def get_status():
    return {"running": pm.is_running()}


@router.post("/start")
async def start_tunnel():
    cfg = await config_mgr.load()
    args = build_run_args(
        mode=cfg.get("mode", "local"),
        token=token_store.get() or "",
        tunnel_name=cfg.get("tunnel_name", ""),
        post_quantum=cfg.get("post_quantum", False),
        log_level=cfg.get("log_level", "info"),
    )
    await pm.start(args)
    return {"success": True, "message": "Tunnel started"}


@router.post("/stop")
async def stop_tunnel():
    await pm.stop()
    return {"success": True, "message": "Tunnel stopped"}


@router.post("/restart")
async def restart_tunnel():
    await pm.restart()
    return {"success": True, "message": "Tunnel restarted"}
