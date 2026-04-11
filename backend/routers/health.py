from fastapi import APIRouter

from ..models.schemas import HealthResponse, ContainerStatus
from ..services.config_manager import ConfigManager
from ..services.podman_manager import PodmanManager

router = APIRouter(tags=["health"])
config_mgr = ConfigManager()
podman_mgr = PodmanManager()


@router.get("/api/health", response_model=HealthResponse)
async def health_check():
    podman_ok = podman_mgr.ping()
    cfg = await config_mgr.load()
    info = podman_mgr.get_status(cfg["container_name"])
    raw_status = info.get("status", "not_found")
    try:
        tunnel_status = ContainerStatus(raw_status)
    except ValueError:
        tunnel_status = ContainerStatus.unknown
    return HealthResponse(
        status="ok" if podman_ok else "degraded",
        podman_connected=podman_ok,
        tunnel_status=tunnel_status,
    )
