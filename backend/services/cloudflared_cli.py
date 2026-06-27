"""Async wrapper around the cloudflared CLI for local-managed tunnel setup."""
import asyncio
import re
from typing import Optional

_LOGIN_URL_RE = re.compile(r"https://dash\.cloudflare\.com/argotunnel\S*")


def extract_login_url(text: str) -> Optional[str]:
    m = _LOGIN_URL_RE.search(text)
    return m.group(0) if m else None


class CloudflaredCLI:
    def __init__(self, binary: str = "cloudflared", origincert: str = "/data/cert.pem"):
        self._binary = binary
        self._origincert = origincert

    async def _run(self, args: list[str]) -> tuple[int, str, str]:
        proc = await asyncio.create_subprocess_exec(
            self._binary, *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await proc.communicate()
        return proc.returncode, out.decode(), err.decode()

    async def create_tunnel(self, name: str, cred_file: str) -> str:
        rc, out, err = await self._run([
            "--origincert", self._origincert, "--cred-file", cred_file,
            "tunnel", "create", name,
        ])
        if rc != 0:
            raise RuntimeError(f"create tunnel failed: {err or out}")
        import json as _json
        from pathlib import Path as _Path
        data = _json.loads(_Path(cred_file).read_text())
        return data["TunnelID"]
