from fastapi import APIRouter

from ..models.schemas import HealthResponse
from ..services.process_manager import ProcessManager

router = APIRouter(tags=["health"])
pm = ProcessManager()


@router.get("/api/health", response_model=HealthResponse)
async def health_check():
    return HealthResponse(status="ok", process_running=pm.is_running())
