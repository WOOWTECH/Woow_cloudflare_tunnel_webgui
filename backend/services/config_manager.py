import json
import asyncio
from pathlib import Path

CONFIG_DIR = Path("/app/config")
CONFIG_FILE = CONFIG_DIR / "settings.json"

DEFAULT_CONFIG = {
    "tunnel_token_secret": "cf-tunnel-token",
    "post_quantum": False,
    "log_level": "info",
    "extra_args": "",
    "container_name": "cloudflared",
    "container_image": "cloudflare/cloudflared:latest",
    "external_hostname": "",
    "additional_hosts": [],
    "tunnel_name": "",
    "catch_all_service": "",
    "nginx_proxy_manager": False,
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
