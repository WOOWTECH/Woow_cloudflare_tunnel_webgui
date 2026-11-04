from pathlib import Path

from fastapi import APIRouter, HTTPException

from ..services import runtime
from ..services.instances import pm, config_mgr, token_store, cli

router = APIRouter(prefix="/api/tunnel", tags=["tunnel"])

DATA_DIR = Path("/data")


@router.get("/status")
async def get_status():
    return {
        "running": pm.is_running(),
        "stopped_by_operator": runtime.stopped_by_operator(DATA_DIR),
    }


async def _apply(message: str):
    try:
        await runtime.apply(pm, config_mgr, token_store, cli, DATA_DIR)
    except runtime.TunnelStartError as exc:
        raise HTTPException(exc.status, exc.message) from exc
    return {"success": True, "message": message}


@router.post("/start")
async def start_tunnel():
    return await _apply("Tunnel started")


@router.post("/stop")
async def stop_tunnel():
    await runtime.stop(pm)
    return {"success": True, "message": "Tunnel stopped"}


@router.post("/restart")
async def restart_tunnel():
    # A fresh argv from the current settings, not ProcessManager.restart(),
    # which would re-run the previous one.
    return await _apply("Tunnel restarted")
