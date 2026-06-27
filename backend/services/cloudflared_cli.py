"""Async wrapper around the cloudflared CLI for local-managed tunnel setup."""
import re
from typing import Optional

_LOGIN_URL_RE = re.compile(r"https://dash\.cloudflare\.com/argotunnel\S*")


def extract_login_url(text: str) -> Optional[str]:
    m = _LOGIN_URL_RE.search(text)
    return m.group(0) if m else None
