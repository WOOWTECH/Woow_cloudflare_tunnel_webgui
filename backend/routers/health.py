from fastapi import APIRouter

from ..models.schemas import HealthResponse
from ..services.instances import pm

router = APIRouter(tags=["health"])


@router.get("/api/health", response_model=HealthResponse)
async def health_check():
    return HealthResponse(status="ok", process_running=pm.is_running())
