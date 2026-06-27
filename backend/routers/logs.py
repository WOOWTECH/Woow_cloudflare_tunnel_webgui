from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..services.process_manager import ProcessManager

router = APIRouter(tags=["logs"])
pm = ProcessManager()


@router.websocket("/ws/logs")
async def stream_logs(websocket: WebSocket):
    await websocket.accept()
    try:
        for line in pm.recent_logs():
            await websocket.send_text(line)
        await websocket.close()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await websocket.send_text(f"[error] {e}")
            await websocket.close()
        except Exception:
            pass
