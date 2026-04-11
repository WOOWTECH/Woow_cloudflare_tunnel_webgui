from fastapi import APIRouter, HTTPException
from podman.errors import APIError

from ..models.schemas import TunnelStatusResponse, ActionResponse, ContainerStatus
from ..services.config_manager import ConfigManager
from ..services.podman_manager import PodmanManager

router = APIRouter(prefix="/api/tunnel", tags=["tunnel"])
config_mgr = ConfigManager()
podman_mgr = PodmanManager()


@router.get("/status", response_model=TunnelStatusResponse)
async def get_status():
    cfg = await config_mgr.load()
    info = podman_mgr.get_status(cfg["container_name"])
    raw_status = info.get("status", "not_found")
    try:
        container_status = ContainerStatus(raw_status)
    except ValueError:
        container_status = ContainerStatus.unknown
    return TunnelStatusResponse(
        status=container_status,
        container_id=info.get("container_id"),
        image=info.get("image"),
        started_at=info.get("started_at"),
        uptime_seconds=info.get("uptime_seconds"),
        exit_code=info.get("exit_code"),
        restart_count=info.get("restart_count", 0),
    )


@router.post("/start", response_model=ActionResponse)
async def start_tunnel():
    cfg = await config_mgr.load()
    secret_name = cfg["tunnel_token_secret"]

    if not podman_mgr.secret_exists(secret_name):
        raise HTTPException(
            400, "Tunnel token not configured. Set it in Config first."
        )

    try:
        cid = podman_mgr.start_container(
            container_name=cfg["container_name"],
            image=cfg["container_image"],
            secret_name=secret_name,
            post_quantum=cfg["post_quantum"],
            log_level=cfg["log_level"],
            extra_args=cfg["extra_args"],
        )
        return ActionResponse(
            success=True, message="Tunnel started", container_id=cid
        )
    except APIError as e:
        raise HTTPException(502, f"Podman error: {e}")
    except Exception as e:
        raise HTTPException(500, f"Failed to start tunnel: {e}")


@router.post("/stop", response_model=ActionResponse)
async def stop_tunnel():
    cfg = await config_mgr.load()
    ok = podman_mgr.stop_container(cfg["container_name"])
    if ok:
        return ActionResponse(success=True, message="Tunnel stopped")
    raise HTTPException(404, "Container not found")


@router.post("/restart", response_model=ActionResponse)
async def restart_tunnel():
    cfg = await config_mgr.load()
    ok = podman_mgr.restart_container(cfg["container_name"])
    if ok:
        return ActionResponse(success=True, message="Tunnel restarted")
    raise HTTPException(404, "Container not found")
