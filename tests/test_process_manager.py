import asyncio
import pytest
from backend.services.process_manager import ProcessManager


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
