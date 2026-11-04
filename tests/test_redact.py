"""
測試: 日誌遮罩(對齊 HA add-on logwatch.clean_line)
涵蓋: token 參數、TunnelSecret、tunnel_token 欄位、裸 token、ANSI 色碼;
ProcessManager 緩衝區與 GET /api/logs 只會有遮罩後的內容
"""

import pytest

from backend.services.process_manager import ProcessManager
from backend.services.redact import clean_line

TOKEN = "eyJ" + "A" * 60


@pytest.mark.parametrize("line", [
    f"cloudflared tunnel run --token {TOKEN}",
    f"cloudflared tunnel run --token={TOKEN}",
    f'{{"AccountTag":"x","TunnelSecret":"{TOKEN}"}}',
    f"tunnel_token: {TOKEN}",
    f"saw {TOKEN} in output",
])
def test_credentials_are_removed(line):
    assert TOKEN not in clean_line(line)


def test_ansi_colour_codes_are_stripped_and_plain_lines_kept():
    assert clean_line("\x1b[32mINF\x1b[0m Registered tunnel connection") == "INF Registered tunnel connection"


@pytest.mark.asyncio
async def test_process_output_is_redacted_before_it_is_buffered():
    pm = ProcessManager()
    await pm.start(["sh", "-c", f"echo 'run --token={TOKEN}'"])
    await pm._reader_task
    assert pm.recent_logs() == ["run --token=<redacted>"]
    await pm.stop()


@pytest.mark.asyncio
async def test_logs_snapshot_endpoint(client, mock_pm):
    mock_pm.recent_logs.return_value = ["INF ok"]
    response = await client.get("/api/logs")
    assert response.status_code == 200
    assert response.json() == {"lines": ["INF ok"]}
