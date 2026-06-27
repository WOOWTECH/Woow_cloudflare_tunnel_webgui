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
            self._logs.append(raw.decode(errors="replace").rstrip("\n"))

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
