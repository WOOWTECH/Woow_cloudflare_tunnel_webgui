"""Manage the cloudflared child process lifecycle (engine-agnostic)."""
import asyncio
import signal
from collections import deque
from typing import Optional


class ProcessManager:
    def __init__(self, log_buffer: int = 500):
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._args: list[str] = []
        self._logs: deque[str] = deque(maxlen=log_buffer)
        self._reader_task: Optional[asyncio.Task] = None
        self._subscribers: set[asyncio.Queue] = set()

    def subscribe(self) -> asyncio.Queue:
        """Register a live log subscriber. Returns a queue fed each new line."""
        q: asyncio.Queue = asyncio.Queue(maxsize=1000)
        self._subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subscribers.discard(q)

    def is_running(self) -> bool:
        return self._proc is not None and self._proc.returncode is None

    async def start(self, args: list[str]) -> None:
        if self.is_running():
            await self.stop()
        self._args = args
        self._proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        self._reader_task = asyncio.create_task(self._read_logs())

    async def _read_logs(self) -> None:
        assert self._proc and self._proc.stdout
        async for raw in self._proc.stdout:
            line = raw.decode(errors="replace").rstrip("\n")
            self._logs.append(line)
            for q in list(self._subscribers):
                try:
                    q.put_nowait(line)
                except asyncio.QueueFull:
                    pass

    async def stop(self, timeout: int = 30) -> None:
        if not self._proc:
            return
        if self._proc.returncode is None:
            self._proc.send_signal(signal.SIGTERM)
            try:
                await asyncio.wait_for(self._proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                self._proc.kill()
                await self._proc.wait()
        self._proc = None
        if self._reader_task:
            self._reader_task.cancel()
            self._reader_task = None

    async def restart(self) -> None:
        args = self._args
        await self.stop()
        await self.start(args)

    def recent_logs(self) -> list[str]:
        return list(self._logs)


def build_run_args(
    mode: str,
    binary: str = "cloudflared",
    token: str = "",
    origincert: str = "/data/cert.pem",
    config: str = "/data/config.json",
    tunnel_name: str = "",
    post_quantum: bool = False,
    log_level: str = "info",
) -> list[str]:
    args = [binary, "tunnel", "--no-autoupdate"]
    if post_quantum:
        args.append("--post-quantum")
    if log_level and log_level != "info":
        args.extend(["--loglevel", log_level])
    if mode == "token":
        args.extend(["run", "--token", token])
    else:
        args.extend(["--origincert", origincert, "--config", config,
                     "run", tunnel_name])
    return args


def autostart_args(
    cfg: dict,
    token: str | None,
    cert_exists: bool,
    tunnel_exists: bool,
    config_exists: bool,
    binary: str = "cloudflared",
) -> list[str] | None:
    """Return cloudflared run args if the tunnel is fully configured, else None.

    Used at container startup to auto-resume the tunnel (parity with the old
    auto-running connector). Token mode needs a token; local mode needs the
    cert, tunnel credentials, and generated ingress config all present.
    """
    mode = cfg.get("mode", "local")
    if mode == "token":
        if not token:
            return None
        return build_run_args(
            mode="token", token=token, binary=binary,
            post_quantum=cfg.get("post_quantum", False),
            log_level=cfg.get("log_level", "info"),
        )
    if cert_exists and tunnel_exists and config_exists:
        return build_run_args(
            mode="local", binary=binary,
            tunnel_name=cfg.get("tunnel_name", ""),
            post_quantum=cfg.get("post_quantum", False),
            log_level=cfg.get("log_level", "info"),
        )
    return None
