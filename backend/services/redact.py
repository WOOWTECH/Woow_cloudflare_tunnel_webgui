"""Remove credentials from log lines before the GUI stores or streams them.

cloudflared at debug level, and anything pasted into a run parameter, can put
a tunnel token or TunnelSecret on its output. The log page, its download and
GET /api/logs must not become a place to read them.
"""
import re

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

REDACTIONS = [
    (re.compile(r"(--token[= ])\S+"), r"\1<redacted>"),
    (re.compile(r"(\"TunnelSecret\"\s*:\s*\")[^\"]+(\")"), r"\1<redacted>\2"),
    (re.compile(r"(tunnel_token[\"']?\s*[:=]\s*[\"']?)[A-Za-z0-9+/=_-]{8,}"), r"\1<redacted>"),
    (re.compile(r"eyJ[A-Za-z0-9+/=_-]{40,}"), "<redacted-token>"),
]


def clean_line(line: str) -> str:
    line = ANSI_RE.sub("", line)
    for pattern, repl in REDACTIONS:
        line = pattern.sub(repl, line)
    return line
