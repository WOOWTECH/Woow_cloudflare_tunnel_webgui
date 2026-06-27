"""Persist the cloudflared tunnel token to a file (single-container, no podman)."""
import os
from pathlib import Path
from typing import Optional


class TokenStore:
    """Store the raw tunnel token on disk with 0600 permissions."""

    def __init__(self, path: "Path | str" = "/data/.tunnel_token"):
        self._path = Path(path)

    def set(self, value: str) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(value)
        os.chmod(self._path, 0o600)

    def get(self) -> Optional[str]:
        if not self._path.exists():
            return None
        return self._path.read_text()

    def has(self) -> bool:
        return self._path.exists()

    def get_masked(self) -> str:
        return "********" if self.has() else ""
