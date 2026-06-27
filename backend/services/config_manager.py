import json
import asyncio
from pathlib import Path

# Persist settings on the /data volume so config survives container recreation
# (TokenStore also uses /data; keeping them together is required for autostart).
CONFIG_DIR = Path("/data")
CONFIG_FILE = CONFIG_DIR / "settings.json"

DEFAULT_CONFIG = {
    "mode": "local",                 # local | token
    "tunnel_name": "",
    "routes": [],                    # [{hostname, service, disableChunkedEncoding}]
    "catch_all_service": "",
    "post_quantum": False,
    "log_level": "info",
    "run_parameters": "",
    "no_tls_verify": True,
    "container_image": "cloudflare/cloudflared:latest",  # 保留供 e2e/相容
}


class ConfigManager:
    def __init__(self, config_path: Path = CONFIG_FILE):
        self._path = config_path
        self._lock = asyncio.Lock()

    async def load(self) -> dict:
        async with self._lock:
            if not self._path.exists():
                await self._save_raw(DEFAULT_CONFIG)
                return dict(DEFAULT_CONFIG)
            text = self._path.read_text()
            return {**DEFAULT_CONFIG, **json.loads(text)}

    async def save(self, data: dict) -> dict:
        async with self._lock:
            merged = {**DEFAULT_CONFIG, **data}
            # Never persist raw token in settings.json
            merged.pop("tunnel_token", None)
            await self._save_raw(merged)
            return merged

    async def _save_raw(self, data: dict) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(json.dumps(data, indent=2))
