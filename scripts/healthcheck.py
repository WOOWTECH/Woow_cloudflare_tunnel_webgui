#!/usr/bin/env python3
"""Container healthcheck for woow-cf-tunnel (baked into the image as
/usr/local/bin/cf-webui-healthcheck; stdlib only).

Healthy means:
  1. the FastAPI backend answers GET /api/health with 200, and
  2. when a tunnel is configured, cloudflared's /ready answers 200 with at
     least one edge connection.

"Configured" mirrors backend/services/process_manager.autostart_args(): token
mode with a non-empty token file, or local mode with cert.pem, tunnel.json and
config.json present. A fresh, unconfigured install therefore stays healthy.
A /data/.tunnel_stopped marker (written by a future GUI "Stop") suppresses the
tunnel check so the healthcheck does not fight an operator's stop.

With HealthOnFailure=kill, 3 consecutive failures make podman kill the
container; systemd (Restart=always) recreates it and the app autostarts
cloudflared. This covers "cloudflared died but the backend is still up", which
the legacy deployment never noticed.

It never reads the token's contents, only whether the file is non-empty.
"""
import json
import os
import sys
import urllib.error
import urllib.request

DATA = os.environ.get("CF_DATA_DIR", "/data")
PORT = os.environ.get("UVICORN_PORT", "8000")
METRICS = os.environ.get("CF_METRICS_ADDR") or "127.0.0.1:20241"
TIMEOUT = float(os.environ.get("CF_HEALTH_TIMEOUT", "4"))


def _get(url: str):
    """(status, body) for any HTTP answer, including 4xx/5xx."""
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def tunnel_expected() -> bool:
    if os.path.exists(os.path.join(DATA, ".tunnel_stopped")):
        return False
    try:
        with open(os.path.join(DATA, "settings.json")) as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return False
    if cfg.get("mode", "local") == "token":
        token = os.path.join(DATA, ".tunnel_token")
        return os.path.isfile(token) and os.path.getsize(token) > 0
    return all(os.path.exists(os.path.join(DATA, f))
               for f in ("cert.pem", "tunnel.json", "config.json"))


def main() -> int:
    try:
        status, _ = _get(f"http://127.0.0.1:{PORT}/api/health")
    except (urllib.error.URLError, OSError) as exc:
        print(f"unhealthy: backend unreachable on 127.0.0.1:{PORT}: {exc}")
        return 1
    if status != 200:
        print(f"unhealthy: backend /api/health returned {status}")
        return 1
    if not tunnel_expected():
        print("healthy: backend ok, tunnel not configured or stopped by operator")
        return 0
    try:
        status, body = _get(f"http://{METRICS}/ready")
        ready = int(json.loads(body).get("readyConnections") or 0)
    except (urllib.error.URLError, OSError, ValueError, AttributeError) as exc:
        print(f"unhealthy: cloudflared /ready on {METRICS}: {exc}")
        return 1
    if status != 200 or ready < 1:
        print(f"unhealthy: cloudflared /ready status={status} readyConnections={ready}")
        return 1
    print(f"healthy: backend ok, cloudflared readyConnections={ready}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
