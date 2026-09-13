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


def test_build_run_args_token_mode_reads_token_from_file():
    args = build_run_args(mode="token", binary="cloudflared",
                          token_file="/data/.tunnel_token")
    assert args == ["cloudflared", "tunnel", "--no-autoupdate",
                    "run", "--token-file", "/data/.tunnel_token"]


def test_build_run_args_token_mode_defaults_to_the_data_volume_file():
    args = build_run_args(mode="token", binary="cloudflared")
    assert args[-2:] == ["--token-file", "/data/.tunnel_token"]


def test_build_run_args_never_puts_a_token_flag_in_argv():
    # Quadlet runs the container inside the unit's cgroup, so
    # `systemctl --user status` prints cloudflared's argv. The token must
    # never be part of it; cloudflared reads it from --token-file instead.
    args = build_run_args(mode="token", binary="cloudflared",
                          token_file="/data/.tunnel_token")
    assert "--token" not in args
    assert not any(a.startswith("--token=") for a in args)


def test_build_run_args_pins_metrics_address_when_given():
    args = build_run_args(mode="token", binary="cloudflared",
                          metrics="127.0.0.1:20241")
    i = args.index("--metrics")
    assert args[i + 1] == "127.0.0.1:20241"
    assert i < args.index("run")  # a `tunnel` flag, not a `run` flag


def test_build_run_args_omits_metrics_by_default():
    args = build_run_args(mode="local", binary="cloudflared", tunnel_name="demo")
    assert "--metrics" not in args


def test_metrics_addr_reads_the_environment(monkeypatch):
    from backend.services.process_manager import metrics_addr
    monkeypatch.setenv("CF_METRICS_ADDR", "127.0.0.1:20241")
    assert metrics_addr() == "127.0.0.1:20241"
    monkeypatch.setenv("CF_METRICS_ADDR", "")
    assert metrics_addr() is None
    monkeypatch.delenv("CF_METRICS_ADDR")
    assert metrics_addr() is None


def test_build_run_args_local_mode():
    args = build_run_args(mode="local", binary="cloudflared",
                          origincert="/data/cert.pem",
                          config="/data/config.json", tunnel_name="demo")
    assert args == ["cloudflared", "tunnel", "--no-autoupdate",
                    "--origincert", "/data/cert.pem",
                    "--config", "/data/config.json", "run", "demo"]


def test_build_run_args_appends_post_quantum_and_loglevel():
    args = build_run_args(mode="token", binary="cloudflared",
                          post_quantum=True, log_level="debug")
    assert "--post-quantum" in args
    assert args[args.index("--loglevel") + 1] == "debug"


# ── autostart_args ─────────────────────────────────────────
from backend.services.process_manager import autostart_args


def test_autostart_token_mode_with_token_returns_args():
    args = autostart_args({"mode": "token"}, token="TOK",
                          cert_exists=False, tunnel_exists=False, config_exists=False,
                          token_file="/data/.tunnel_token")
    assert args is not None
    assert args[-2:] == ["--token-file", "/data/.tunnel_token"]
    assert "TOK" not in args and "--token" not in args


def test_autostart_passes_metrics_address():
    args = autostart_args({"mode": "token"}, token="TOK",
                          cert_exists=False, tunnel_exists=False, config_exists=False,
                          metrics="127.0.0.1:20241")
    assert args[args.index("--metrics") + 1] == "127.0.0.1:20241"


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


# ── log pub/sub (live streaming) ───────────────────────────
@pytest.mark.asyncio
async def test_subscribe_receives_new_log_lines():
    pm = ProcessManager()
    q = pm.subscribe()
    await pm.start(["sh", "-c", "sleep 0.3; echo streamed-line; sleep 5"])
    line = await asyncio.wait_for(q.get(), timeout=4)
    assert line == "streamed-line"
    await pm.stop(timeout=5)


@pytest.mark.asyncio
async def test_unsubscribe_stops_delivery():
    pm = ProcessManager()
    q = pm.subscribe()
    assert q in pm._subscribers
    pm.unsubscribe(q)
    assert q not in pm._subscribers
