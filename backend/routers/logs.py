import asyncio

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..services.instances import pm

router = APIRouter(tags=["logs"])


@router.websocket("/ws/logs")
async def stream_logs(websocket: WebSocket):
    """Stream cloudflared logs: send the backlog, then keep the connection open
    and push each new line as it arrives. Staying open avoids the client's
    reconnect loop (which previously caused connect/disconnect flicker)."""
    await websocket.accept()
    queue = pm.subscribe()
    # Watches for client disconnect so an idle (no new logs) connection still
    # gets cleaned up instead of blocking forever on queue.get().
    receiver = asyncio.create_task(_watch_disconnect(websocket))
    try:
        for line in pm.recent_logs():
            await websocket.send_text(line)
        while True:
            getter = asyncio.create_task(queue.get())
            done, _ = await asyncio.wait(
                {getter, receiver}, return_when=asyncio.FIRST_COMPLETED
            )
            if receiver in done:
                getter.cancel()
                break
            await websocket.send_text(getter.result())
    except (WebSocketDisconnect, RuntimeError):
        pass
    except Exception:
        pass
    finally:
        receiver.cancel()
        pm.unsubscribe(queue)


async def _watch_disconnect(websocket: WebSocket) -> None:
    """Resolve when the client disconnects (receive raises)."""
    try:
        while True:
            await websocket.receive()
    except Exception:
        return
