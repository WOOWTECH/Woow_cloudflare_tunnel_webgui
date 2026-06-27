import asyncio
import pytest
from backend.services.process_manager import ProcessManager, build_run_args


@pytest.mark.asyncio
async def test_start_then_running_then_stop():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "sleep 30"])
    assert pm.is_running() is True
    await pm.stop(timeout=5)
    assert pm.is_running() is False


@pytest.mark.asyncio
async def test_captures_stdout_into_log_buffer():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "echo line-one; echo line-two; sleep 5"])
    await asyncio.sleep(0.3)   # 讓 reader 收到
    logs = pm.recent_logs()
    assert "line-one" in logs
    assert "line-two" in logs
    await pm.stop(timeout=5)


@pytest.mark.asyncio
async def test_restart_keeps_args_and_runs_again():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "sleep 30"])
    first_pid = pm._proc.pid
    await pm.restart()
    assert pm.is_running() is True
    assert pm._proc.pid != first_pid   # 是新行程
    await pm.stop(timeout=5)


@pytest.mark.asyncio
async def test_stop_is_idempotent_on_exited_process():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "exit 0"])
    await asyncio.sleep(0.2)
    await pm.stop(timeout=5)     # 不應拋例外
    assert pm.is_running() is False
    await pm.stop(timeout=5)     # 再次 stop 仍安全
    assert pm.is_running() is False


def test_build_run_args_token_mode():
    args = build_run_args(mode="token", token="TOK", binary="cloudflared")
    assert args == ["cloudflared", "tunnel", "--no-autoupdate",
                    "run", "--token", "TOK"]


def test_build_run_args_local_mode():
    args = build_run_args(mode="local", binary="cloudflared",
                          origincert="/data/cert.pem",
                          config="/data/config.json", tunnel_name="demo")
    assert args == ["cloudflared", "tunnel", "--no-autoupdate",
                    "--origincert", "/data/cert.pem",
                    "--config", "/data/config.json", "run", "demo"]


def test_build_run_args_appends_post_quantum_and_loglevel():
    args = build_run_args(mode="token", token="T", binary="cloudflared",
                          post_quantum=True, log_level="debug")
    assert "--post-quantum" in args
    assert args[args.index("--loglevel") + 1] == "debug"


# ── autostart_args ─────────────────────────────────────────
from backend.services.process_manager import autostart_args


def test_autostart_token_mode_with_token_returns_args():
    args = autostart_args({"mode": "token"}, token="TOK",
                          cert_exists=False, tunnel_exists=False, config_exists=False)
    assert args is not None
    assert "--token" in args and "TOK" in args


def test_autostart_token_mode_without_token_returns_none():
    args = autostart_args({"mode": "token"}, token=None,
                          cert_exists=False, tunnel_exists=False, config_exists=False)
    assert args is None


def test_autostart_local_mode_all_files_present_returns_args():
    args = autostart_args({"mode": "local", "tunnel_name": "demo"}, token=None,
                          cert_exists=True, tunnel_exists=True, config_exists=True)
    assert args is not None
    assert args[-2:] == ["run", "demo"]


def test_autostart_local_mode_missing_config_returns_none():
    args = autostart_args({"mode": "local", "tunnel_name": "demo"}, token=None,
                          cert_exists=True, tunnel_exists=True, config_exists=False)
    assert args is None
