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
