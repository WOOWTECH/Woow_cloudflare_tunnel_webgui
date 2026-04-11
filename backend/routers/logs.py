import asyncio

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..services.config_manager import ConfigManager
from ..services.podman_manager import PodmanManager

router = APIRouter(tags=["logs"])
config_mgr = ConfigManager()
podman_mgr = PodmanManager()


async def _stream_blocking_logs(log_iter, websocket: WebSocket):
    """Bridge blocking podman log iterator to async WebSocket."""
    loop = asyncio.get_event_loop()

    def _next():
        try:
            return next(log_iter)
        except StopIteration:
            return None

    while True:
        chunk = await loop.run_in_executor(None, _next)
        if chunk is None:
            break
        if isinstance(chunk, bytes):
            line = chunk.decode("utf-8", errors="replace").strip()
        else:
            line = str(chunk).strip()
        if line:
            await websocket.send_text(line)


@router.websocket("/ws/logs")
async def stream_logs(websocket: WebSocket):
    await websocket.accept()

    cfg = await config_mgr.load()
    container_name = cfg["container_name"]

    try:
        log_iter = podman_mgr.stream_logs(container_name, tail=200)
        await _stream_blocking_logs(log_iter, websocket)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await websocket.send_text(f"[error] {e}")
            await websocket.close()
        except Exception:
            pass
