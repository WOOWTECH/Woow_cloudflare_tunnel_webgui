"""Tests for scripts/healthcheck.py (baked into the image as
/usr/local/bin/cf-webui-healthcheck and used by the Quadlet unit's HealthCmd).

The script runs as a subprocess against two local HTTP servers standing in for
the FastAPI backend (/api/health) and cloudflared's metrics server (/ready).
No containers, no network beyond 127.0.0.1.
"""
import json
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "healthcheck.py"


class _Server:
    """Tiny HTTP server: routes[path] = (status, body)."""

    def __init__(self, routes):
        self.routes = routes
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 (http.server API)
                status, body = outer.routes.get(self.path, (404, "{}"))
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture()
def servers():
    made = []

    def make(routes):
        srv = _Server(routes)
        made.append(srv)
        return srv

    yield make
    for srv in made:
        srv.close()


def _run(data_dir, backend_port, metrics_port):
    env = {
        "PATH": "/usr/bin:/bin",
        "CF_DATA_DIR": str(data_dir),
        "UVICORN_PORT": str(backend_port),
        "CF_METRICS_ADDR": f"127.0.0.1:{metrics_port}",
        "CF_HEALTH_TIMEOUT": "2",
    }
    proc = subprocess.run([sys.executable, str(SCRIPT)], env=env,
                          capture_output=True, text=True, timeout=20)
    return proc.returncode, proc.stdout.strip()


BACKEND_OK = {"/api/health": (200, '{"status":"ok","process_running":true}')}


def _ready(n, status=200):
    return {"/ready": (status, json.dumps({"status": status, "readyConnections": n}))}


def _token_mode(data_dir, token="eyJhIjoiYiJ9"):
    (data_dir / "settings.json").write_text('{"mode":"token"}')
    if token is not None:
        (data_dir / ".tunnel_token").write_text(token)


def _local_mode(data_dir, files=("cert.pem", "tunnel.json", "config.json")):
    (data_dir / "settings.json").write_text('{"mode":"local","tunnel_name":"t"}')
    for f in files:
        (data_dir / f).write_text("x")


# ── healthy ─────────────────────────────────────────────────


def test_fresh_install_without_settings_is_healthy(tmp_path, servers):
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 0, out
    assert "not configured" in out


def test_token_mode_without_token_file_is_healthy(tmp_path, servers):
    _token_mode(tmp_path, token=None)
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 0, out


def test_token_mode_with_empty_token_file_is_healthy(tmp_path, servers):
    _token_mode(tmp_path, token="")
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 0, out


def test_configured_token_mode_with_ready_connections_is_healthy(tmp_path, servers):
    _token_mode(tmp_path)
    backend, metrics = servers(BACKEND_OK), servers(_ready(4))
    rc, out = _run(tmp_path, backend.port, metrics.port)
    assert rc == 0, out
    assert "readyConnections=4" in out


def test_operator_stop_marker_suppresses_the_tunnel_check(tmp_path, servers):
    _token_mode(tmp_path)
    (tmp_path / ".tunnel_stopped").write_text("")
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 0, out


def test_local_mode_partially_configured_is_healthy(tmp_path, servers):
    _local_mode(tmp_path, files=("cert.pem",))
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 0, out


def test_local_mode_fully_configured_and_ready_is_healthy(tmp_path, servers):
    _local_mode(tmp_path)
    backend, metrics = servers(BACKEND_OK), servers(_ready(2))
    rc, out = _run(tmp_path, backend.port, metrics.port)
    assert rc == 0, out


# ── unhealthy ───────────────────────────────────────────────


def test_cloudflared_not_ready_503_is_unhealthy(tmp_path, servers):
    _token_mode(tmp_path)
    backend, metrics = servers(BACKEND_OK), servers(_ready(0, status=503))
    rc, out = _run(tmp_path, backend.port, metrics.port)
    assert rc == 1, out


def test_ready_200_with_zero_connections_is_unhealthy(tmp_path, servers):
    _token_mode(tmp_path)
    backend, metrics = servers(BACKEND_OK), servers(_ready(0))
    rc, out = _run(tmp_path, backend.port, metrics.port)
    assert rc == 1, out
    assert "readyConnections=0" in out


def test_backend_500_is_unhealthy(tmp_path, servers):
    backend = servers({"/api/health": (500, "{}")})
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 1, out


def test_backend_down_is_unhealthy(tmp_path):
    rc, out = _run(tmp_path, _free_port(), _free_port())
    assert rc == 1, out
    assert "backend unreachable" in out


def test_metrics_port_closed_while_tunnel_expected_is_unhealthy(tmp_path, servers):
    _local_mode(tmp_path)
    backend = servers(BACKEND_OK)
    rc, out = _run(tmp_path, backend.port, _free_port())
    assert rc == 1, out
    assert "/ready" in out


def test_output_never_contains_the_token(tmp_path, servers):
    _token_mode(tmp_path, token="eyJzZWNyZXQiOiJkby1ub3QtbGVhayJ9")
    backend, metrics = servers(BACKEND_OK), servers(_ready(0))
    rc, out = _run(tmp_path, backend.port, metrics.port)
    assert "do-not-leak" not in out and "eyJzZWNyZXQi" not in out
