"""Tunnel status from cloudflared's metrics /ready endpoint.

/ready reports the number of edge connections. It is the same signal the
container healthcheck uses, so the GUI and the liveness check agree. When
cloudflared is not running the port is closed and the tunnel is "stopped".
"""
import aiohttp

from ..models.schemas import TunnelStatus
from .process_manager import effective_metrics_addr


async def tunnel_status() -> TunnelStatus:
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"http://{effective_metrics_addr()}/ready",
                timeout=aiohttp.ClientTimeout(total=3.0),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json(content_type=None)
                    ready = int(data.get("readyConnections") or 0)
                    return TunnelStatus(
                        status="running" if ready > 0 else "starting",
                        ready_connections=ready,
                        metrics_reachable=True,
                    )
                return TunnelStatus(status="starting", metrics_reachable=True)
    except Exception:
        return TunnelStatus(status="stopped", metrics_reachable=False)
