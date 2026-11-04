from pathlib import Path

from fastapi import APIRouter

from .. import __version__
from ..models.schemas import HealthResponse
from ..services import metrics, runtime
from ..services.instances import pm

router = APIRouter(tags=["health"])

DATA_DIR = Path("/data")


@router.get("/api/health", response_model=HealthResponse)
async def health_check():
    # Always 200 while the backend is up: scripts/healthcheck.py reads the
    # tunnel's /ready itself, so a tunnel problem must not fail this endpoint.
    return HealthResponse(
        status="ok",
        version=__version__,
        process_running=pm.is_running(),
        stopped_by_operator=runtime.stopped_by_operator(DATA_DIR),
        tunnel=await metrics.tunnel_status(),
        credentials_error=runtime.credentials_error,
    )
