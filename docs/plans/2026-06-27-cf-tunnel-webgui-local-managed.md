# Cloudflare Tunnel Web GUI(通用本地管理版)Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 `Woow_cloudflare_tunnel_webgui` 重構成「單一容器、Docker/Podman 通用」的 Cloudflare Tunnel 自助設定工具:使用者用自己 `cloudflared tunnel login` 的 cert.pem 授權,GUI 產生 config.json 並以子行程跑 cloudflared(本地管理模式),自動建立 DNS。

**Architecture:** 單一容器內 FastAPI(後端)+ Vue3 SPA(前端)+ 內建 cloudflared 二進位。後端用 asyncio subprocess 管理 cloudflared 行程(取代 Podman SDK),產生 `/data/{cert.pem,tunnel.json,config.json}`。Token 模式直通,本地模式走 login→create→build config→route dns→run 的自助鏈。

**Tech Stack:** Python 3.12 / FastAPI 0.115 / Pydantic 2.10 / pytest(asyncio_mode=auto)/ httpx TestClient / Vue 3 + TS + Vite + Vitest / cloudflared CLI。

---

## 設計依據

完整設計見 `docs/plans/2026-06-27-cf-tunnel-webgui-local-managed-design.md`。本計畫是其逐步 TDD 落地。

## 測試策略(全程適用)

- **每個任務嚴格 TDD**:先寫失敗測試 → 跑驗證失敗 → 最小實作 → 跑驗證通過 → commit。
- **三層測試**:
  1. **純邏輯單元測試**(config_builder、URL 解析、schema 驗證)— 不碰 IO,涵蓋所有邊界。
  2. **子行程/包裝層測試**(cloudflared_cli、process_manager)— 用 `monkeypatch` 替換 `asyncio.create_subprocess_exec` 為假行程,或用真實短命令(`sh -c`)做生命週期測試,不依賴真的 cloudflared。
  3. **路由整合測試**(routers)— 用既有 `client` fixture(httpx ASGITransport),把 service 層 mock 掉。
- **不依賴真實 Cloudflare**:所有 cloudflared 呼叫在單元/整合層一律 mock;真連線只在 `@pytest.mark.e2e`(預設 deselect)。
- **每個測試只驗一件事**,命名 `test_<單元>_<情境>_<預期>`。
- **覆蓋率門檻**:核心 service(config_builder/cloudflared_cli/process_manager/config_manager)目標行覆蓋 100%,分支涵蓋所有 if/else。
- **執行指令基準**:
  - 單元+整合:`python -m pytest -m "not e2e" -v`
  - 單檔單測:`python -m pytest tests/<file>::<test> -v`
  - 前端:`cd frontend && npx vitest run`

## 階段總覽

| Phase | 內容 | 產出 |
|---|---|---|
| 0 | 測試基建 + 依賴調整 + 移除 Podman 層的前置 | requirements、conftest、pytest 標記 |
| 1 | `config_builder`(純邏輯,ingress 產生) | services/config_builder.py |
| 2 | schemas(Route / Mode / Setup 狀態 + 驗證) | models/schemas.py |
| 3 | `cloudflared_cli`(subprocess 包裝 + URL 解析) | services/cloudflared_cli.py |
| 4 | `process_manager`(cloudflared 子行程生命週期) | services/process_manager.py |
| 5 | `config_manager`(去 HA、加 mode/routes) | services/config_manager.py |
| 6 | routers(setup / tunnel / config / logs 改寫) | routers/*.py |
| 7 | Dockerfile / compose(單容器 + cloudflared binary) | Dockerfile, docker-compose.yml |
| 8 | 前端(上線精靈 + 路由編輯器) | frontend/src/** |
| 9 | 整合 / e2e 煙霧測試 | tests/test_e2e_live.py |

---

## Phase 0:測試基建與前置

### Task 0.1:調整 Python 依賴(移除 podman,加測試工具)

**Files:**
- Modify: `backend/requirements.txt`
- Create: `requirements-dev.txt`

**Step 1: 改 `backend/requirements.txt`** — 移除 `podman>=5.2.0`(不再用 Podman SDK),其餘保留:

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
pydantic==2.10.4
pydantic-settings==2.7.1
starlette-csrf==3.0.0
websockets==14.2
aiofiles==24.1.0
```

**Step 2: 建 `requirements-dev.txt`**:

```
-r backend/requirements.txt
pytest==8.3.4
pytest-asyncio==0.25.0
httpx==0.28.1
```

**Step 3: 安裝並確認現有測試可收集**

Run: `python -m pip install -r requirements-dev.txt`
Run: `python -m pytest --collect-only -q`
Expected: 能收集到既有測試(部分將在後續任務被取代/刪除,先確認環境可跑)。

**Step 4: Commit**

```bash
git add backend/requirements.txt requirements-dev.txt
git commit -m "chore: 移除 podman SDK 依賴,新增 dev 測試依賴"
```

### Task 0.2:標記既有 Podman 相關測試為待淘汰

**Files:**
- Modify: `tests/conftest.py`(暫時保留 `mock_podman` 以免 import 爆掉,後續 Phase 6 移除)

**Step 1:** 在 `tests/conftest.py` 頂部加註解標明後續移除範圍(不改行為),確保收集不報錯。

**Step 2: Commit**

```bash
git add tests/conftest.py
git commit -m "chore: 標註 podman fixture 待 Phase 6 移除"
```

> 註:Phase 0 不動核心邏輯,只把地基鋪好。真正的 TDD 從 Phase 1 開始。

---

## Phase 1:`config_builder`(ingress config.json 純邏輯)

**目標函式:** `build_ingress_config(tunnel_uuid, credentials_file, routes, catch_all_service=None, no_tls_verify=True) -> dict`,輸出 cloudflared config(dict)。純函式、零 IO,逐邊界 TDD。

**資料形狀:** `routes` 是 `[{"hostname": str, "service": str, "disableChunkedEncoding": bool|None}, ...]`。

**輸出規則(對齊 add-on `createConfig`):**
- 頂層:`{"tunnel": uuid, "credentials-file": cred_file}`。
- `ingress`:每個 route → `{"hostname", "service", "originRequest": {...}}`。
- `disableChunkedEncoding` 為 True/False 時寫入 `originRequest`;為 None/缺省則不寫該鍵。
- `no_tls_verify=True` → 每筆(含 catch-all)`originRequest.noTLSVerify=true`。
- 最後一筆為 catch-all:只有 `service`(= `catch_all_service` 或 `"http_status:404"`)。

**Files:**
- Create: `backend/services/config_builder.py`
- Test: `tests/test_config_builder.py`

### Task 1.1:最小骨架 — 空 routes 只產生 catch-all 404

**Step 1: 寫失敗測試** — `tests/test_config_builder.py`

```python
from backend.services.config_builder import build_ingress_config


def test_empty_routes_produces_only_catch_all_404():
    cfg = build_ingress_config(
        tunnel_uuid="uuid-123",
        credentials_file="/data/tunnel.json",
        routes=[],
    )
    assert cfg["tunnel"] == "uuid-123"
    assert cfg["credentials-file"] == "/data/tunnel.json"
    assert cfg["ingress"] == [
        {"service": "http_status:404", "originRequest": {"noTLSVerify": True}}
    ]
```

**Step 2: 跑驗證失敗**

Run: `python -m pytest tests/test_config_builder.py::test_empty_routes_produces_only_catch_all_404 -v`
Expected: FAIL — `ModuleNotFoundError: backend.services.config_builder`。

**Step 3: 最小實作** — `backend/services/config_builder.py`

```python
"""Pure functions that turn route config into a cloudflared ingress config dict."""
from typing import Optional


def build_ingress_config(
    tunnel_uuid: str,
    credentials_file: str,
    routes: list[dict],
    catch_all_service: Optional[str] = None,
    no_tls_verify: bool = True,
) -> dict:
    ingress: list[dict] = []
    for route in routes:
        entry = {"hostname": route["hostname"], "service": route["service"]}
        origin: dict = {}
        dce = route.get("disableChunkedEncoding")
        if dce is not None:
            origin["disableChunkedEncoding"] = dce
        if no_tls_verify:
            origin["noTLSVerify"] = True
        if origin:
            entry["originRequest"] = origin
        ingress.append(entry)

    catch = {"service": catch_all_service or "http_status:404"}
    if no_tls_verify:
        catch["originRequest"] = {"noTLSVerify": True}
    ingress.append(catch)

    return {
        "tunnel": tunnel_uuid,
        "credentials-file": credentials_file,
        "ingress": ingress,
    }
```

**Step 4: 跑驗證通過**

Run: `python -m pytest tests/test_config_builder.py::test_empty_routes_produces_only_catch_all_404 -v`
Expected: PASS。

**Step 5: Commit**

```bash
git add backend/services/config_builder.py tests/test_config_builder.py
git commit -m "feat: config_builder 產生空 routes 的 catch-all 404"
```

### Task 1.2:單一 route — hostname/service + noTLSVerify

**Step 1: 追加測試**

```python
def test_single_route_has_hostname_service_and_no_tls_verify():
    cfg = build_ingress_config(
        "uuid", "/data/tunnel.json",
        routes=[{"hostname": "a.example.com", "service": "http://localhost:8080"}],
    )
    assert cfg["ingress"][0] == {
        "hostname": "a.example.com",
        "service": "http://localhost:8080",
        "originRequest": {"noTLSVerify": True},
    }
    # catch-all 仍在最後
    assert cfg["ingress"][-1]["service"] == "http_status:404"
```

**Step 2: 跑驗證**(已可能通過,因實作已支援)

Run: `python -m pytest tests/test_config_builder.py::test_single_route_has_hostname_service_and_no_tls_verify -v`
Expected: PASS（若失敗則修實作)。

**Step 3: Commit**

```bash
git add tests/test_config_builder.py
git commit -m "test: 單一 route 的 ingress 結構"
```

### Task 1.3:`disableChunkedEncoding` 三態(True / False / 缺省)

**Step 1: 追加三個測試**

```python
def test_disable_chunked_true_written_to_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[
        {"hostname": "h", "service": "s", "disableChunkedEncoding": True}])
    assert cfg["ingress"][0]["originRequest"]["disableChunkedEncoding"] is True


def test_disable_chunked_false_written_to_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[
        {"hostname": "h", "service": "s", "disableChunkedEncoding": False}])
    assert cfg["ingress"][0]["originRequest"]["disableChunkedEncoding"] is False


def test_disable_chunked_absent_not_in_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[{"hostname": "h", "service": "s"}])
    assert "disableChunkedEncoding" not in cfg["ingress"][0]["originRequest"]
```

**Step 2: 跑驗證**

Run: `python -m pytest tests/test_config_builder.py -k disable_chunked -v`
Expected: PASS x3。

**Step 3: Commit**

```bash
git add tests/test_config_builder.py
git commit -m "test: disableChunkedEncoding 三態行為"
```

### Task 1.4:catch_all_service 取代 404

**Step 1: 追加測試**

```python
def test_catch_all_service_replaces_404():
    cfg = build_ingress_config("u", "/c", routes=[],
                               catch_all_service="http://192.168.1.100")
    assert cfg["ingress"][-1] == {
        "service": "http://192.168.1.100",
        "originRequest": {"noTLSVerify": True},
    }
```

**Step 2: 跑驗證 → PASS。Step 3: Commit**

```bash
git add tests/test_config_builder.py
git commit -m "test: catch_all_service 覆寫預設 404"
```

### Task 1.5:`no_tls_verify=False` 時不加 noTLSVerify

**Step 1: 追加測試**

```python
def test_no_tls_verify_false_omits_origin_request_key():
    cfg = build_ingress_config("u", "/c",
        routes=[{"hostname": "h", "service": "s"}], no_tls_verify=False)
    assert "originRequest" not in cfg["ingress"][0]   # 無任何 origin 設定 → 不產生空 dict
    assert "originRequest" not in cfg["ingress"][-1]   # catch-all 同理
```

**Step 2: 跑驗證**

Run: `python -m pytest tests/test_config_builder.py::test_no_tls_verify_false_omits_origin_request_key -v`
Expected: PASS（實作中 `if origin:` 已保證空 dict 不寫;catch-all 同理)。

**Step 3: Commit**

```bash
git add tests/test_config_builder.py
git commit -m "test: no_tls_verify=False 不產生 originRequest"
```

### Task 1.6:多 route 順序保留 + catch-all 永遠最後

**Step 1: 追加測試**

```python
def test_multiple_routes_preserve_order_with_catch_all_last():
    routes = [
        {"hostname": "a", "service": "s1"},
        {"hostname": "b", "service": "s2"},
        {"hostname": "c", "service": "s3"},
    ]
    cfg = build_ingress_config("u", "/c", routes=routes)
    hosts = [e.get("hostname") for e in cfg["ingress"]]
    assert hosts == ["a", "b", "c", None]   # None = catch-all
    assert cfg["ingress"][-1]["service"] == "http_status:404"
```

**Step 2: 跑驗證 → PASS。Step 3: Commit**

```bash
git add tests/test_config_builder.py
git commit -m "test: 多 route 順序與 catch-all 結尾"
```

### Task 1.7:寫檔輔助 + 全檔測試綠燈

**Step 1: 追加 `write_config_json` 測試**(寫入並可被 json 讀回)

```python
import json
from backend.services.config_builder import write_config_json


def test_write_config_json_roundtrip(tmp_path):
    cfg = build_ingress_config("u", "/c", routes=[{"hostname": "h", "service": "s"}])
    out = tmp_path / "config.json"
    write_config_json(cfg, out)
    assert json.loads(out.read_text()) == cfg
```

**Step 2: 跑驗證失敗** — `write_config_json` 未定義。

**Step 3: 實作** — 追加到 `config_builder.py`：

```python
import json
from pathlib import Path


def write_config_json(config: dict, path: "Path | str") -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2))
```

**Step 4: 跑整個 Phase 1 測試檔**

Run: `python -m pytest tests/test_config_builder.py -v`
Expected: 全部 PASS(約 9 個測試)。

**Step 5: Commit**

```bash
git add backend/services/config_builder.py tests/test_config_builder.py
git commit -m "feat: write_config_json 寫檔輔助"
```

---

## Phase 2:Schemas(Route / Mode / Setup 狀態 + 驗證)

去 HA 化:移除 `external_hostname` 自動偵測、`nginx_proxy_manager`。新增 `Route`、`TunnelMode`、setup 狀態模型。hostname 驗證採用 add-on 的 regex(小寫、無協定、無埠)。

**Files:**
- Modify: `backend/models/schemas.py`
- Test: `tests/test_schemas.py`(取代既有,聚焦新模型)

### Task 2.1:`TunnelMode` enum

**Step 1: 失敗測試** — `tests/test_schemas.py`

```python
from backend.models.schemas import TunnelMode


def test_tunnel_mode_values():
    assert TunnelMode.local.value == "local"
    assert TunnelMode.token.value == "token"
```

**Step 2: 跑驗證失敗。Step 3: 實作** — 在 `schemas.py` 加:

```python
class TunnelMode(str, Enum):
    local = "local"
    token = "token"
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/models/schemas.py tests/test_schemas.py
git commit -m "feat: TunnelMode enum"
```

### Task 2.2:`Route` — 合法 hostname 通過

**Step 1: 失敗測試**

```python
from backend.models.schemas import Route


def test_route_accepts_valid_hostname_and_service():
    r = Route(hostname="app.example.com", service="http://localhost:8080")
    assert r.hostname == "app.example.com"
    assert r.service == "http://localhost:8080"
    assert r.disableChunkedEncoding is False   # 預設
```

**Step 2: 失敗。Step 3: 實作**

```python
VALID_HOSTNAME_RE = re.compile(
    r"^(([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])\.)*"
    r"([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$"
)


class Route(BaseModel):
    hostname: str
    service: str
    disableChunkedEncoding: bool = False

    @field_validator("hostname")
    @classmethod
    def _valid_hostname(cls, v: str) -> str:
        v = v.strip().lower()
        if not v:
            raise ValueError("hostname 不可為空")
        if not VALID_HOSTNAME_RE.match(v):
            raise ValueError("hostname 不可含協定(http://)或埠(:8123),且須小寫")
        return v

    @field_validator("service")
    @classmethod
    def _valid_service(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("service 不可為空")
        return v
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/models/schemas.py tests/test_schemas.py
git commit -m "feat: Route 模型與合法 hostname"
```

### Task 2.3:`Route` — 拒絕協定 / 埠 / 大寫 / 空白

**Step 1: 參數化失敗測試**

```python
import pytest
from pydantic import ValidationError


@pytest.mark.parametrize("bad", [
    "https://app.example.com",   # 含協定
    "app.example.com:8123",      # 含埠
    "App.Example.com",           # 大寫(會被 lower 後仍合法 → 見下說明)
    "",                          # 空
    "   ",                       # 純空白
])
def test_route_rejects_invalid_hostname(bad):
    if bad.strip().lower() == "app.example.com":
        pytest.skip("大寫會被正規化為合法,改由 2.4 驗證")
    with pytest.raises(ValidationError):
        Route(hostname=bad, service="http://x")
```

> 說明:大寫經 `.lower()` 後合法,屬「正規化」非「拒絕」。2.4 專測正規化。

**Step 2: 跑驗證 → PASS(協定/埠/空白都應被擋)。Step 3: Commit**

```bash
git add tests/test_schemas.py
git commit -m "test: Route 拒絕協定/埠/空白"
```

### Task 2.4:`Route` — 大寫正規化為小寫

**Step 1: 失敗測試**

```python
def test_route_lowercases_hostname():
    r = Route(hostname="App.Example.COM", service="http://x")
    assert r.hostname == "app.example.com"
```

**Step 2: PASS(實作已 `.lower()`)。Step 3: Commit**

```bash
git add tests/test_schemas.py
git commit -m "test: hostname 正規化為小寫"
```

### Task 2.5:Setup 狀態模型 `SetupState`

**Step 1: 失敗測試**

```python
from backend.models.schemas import SetupState


def test_setup_state_serializes():
    s = SetupState(has_cert=False, has_tunnel=False, tunnel_uuid=None,
                   mode=TunnelMode.local)
    d = s.model_dump()
    assert d == {"has_cert": False, "has_tunnel": False,
                 "tunnel_uuid": None, "mode": "local"}
```

**Step 2: 失敗。Step 3: 實作**

```python
class SetupState(BaseModel):
    has_cert: bool
    has_tunnel: bool
    tunnel_uuid: Optional[str] = None
    mode: TunnelMode = TunnelMode.local
```

**Step 4: PASS。Step 5: 全檔測試**

Run: `python -m pytest tests/test_schemas.py -v`
Expected: 全 PASS。

**Step 6: Commit**

```bash
git add backend/models/schemas.py tests/test_schemas.py
git commit -m "feat: SetupState 模型"
```

---

## Phase 3:`cloudflared_cli`(subprocess 包裝 + login URL 解析)

把 cloudflared CLI 包成 async 方法。**關鍵可測純函式**:`extract_login_url(text)`。subprocess 互動一律以 monkeypatch 假行程測試,不跑真 cloudflared。

**Files:**
- Create: `backend/services/cloudflared_cli.py`
- Test: `tests/test_cloudflared_cli.py`

### Task 3.1:`extract_login_url` — 從輸出抓授權 URL

**Step 1: 失敗測試**

```python
from backend.services.cloudflared_cli import extract_login_url


def test_extract_login_url_finds_argotunnel_url():
    text = (
        "Please open the following URL and log in with your Cloudflare account:\n\n"
        "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin\n\n"
        "Leave cloudflared running to download the cert automatically.\n"
    )
    url = extract_login_url(text)
    assert url == "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin"


def test_extract_login_url_returns_none_when_absent():
    assert extract_login_url("no url here") is None
```

**Step 2: 失敗。Step 3: 實作** — `backend/services/cloudflared_cli.py`

```python
"""Async wrapper around the cloudflared CLI for local-managed tunnel setup."""
import re
from typing import Optional

_LOGIN_URL_RE = re.compile(r"https://dash\.cloudflare\.com/argotunnel\S*")


def extract_login_url(text: str) -> Optional[str]:
    m = _LOGIN_URL_RE.search(text)
    return m.group(0) if m else None
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: extract_login_url 解析授權 URL"
```

### Task 3.2:`_run` — 執行指令回傳 (rc, stdout, stderr)

**Step 1: 失敗測試**(用真實 `echo`/`false`,屬行程非 socket,pytest-socket 不擋)

```python
import pytest
from backend.services.cloudflared_cli import CloudflaredCLI


@pytest.mark.asyncio
async def test_run_returns_stdout_and_zero_rc():
    cli = CloudflaredCLI(binary="/bin/echo")
    rc, out, err = await cli._run(["hello"])
    assert rc == 0
    assert out.strip() == "hello"


@pytest.mark.asyncio
async def test_run_nonzero_rc_on_false():
    cli = CloudflaredCLI(binary="/usr/bin/false")
    rc, out, err = await cli._run([])
    assert rc != 0
```

**Step 2: 失敗。Step 3: 實作** — 追加:

```python
import asyncio


class CloudflaredCLI:
    def __init__(self, binary: str = "cloudflared", origincert: str = "/data/cert.pem"):
        self._binary = binary
        self._origincert = origincert

    async def _run(self, args: list[str]) -> tuple[int, str, str]:
        proc = await asyncio.create_subprocess_exec(
            self._binary, *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await proc.communicate()
        return proc.returncode, out.decode(), err.decode()
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: CloudflaredCLI._run 執行包裝"
```

### Task 3.3:`create_tunnel` — 解析 tunnel.json 取得 UUID

**Step 1: 失敗測試**(monkeypatch `_run` 假裝成功,並預先放一個 tunnel.json)

```python
import json
import pytest


@pytest.mark.asyncio
async def test_create_tunnel_returns_uuid(tmp_path, monkeypatch):
    cred = tmp_path / "tunnel.json"

    async def fake_run(args):
        cred.write_text(json.dumps({"TunnelID": "uuid-xyz", "AccountTag": "a"}))
        return 0, "Created tunnel demo with id uuid-xyz", ""

    cli = CloudflaredCLI(binary="cloudflared")
    monkeypatch.setattr(cli, "_run", fake_run)
    uuid = await cli.create_tunnel(name="demo", cred_file=str(cred))
    assert uuid == "uuid-xyz"


@pytest.mark.asyncio
async def test_create_tunnel_raises_on_failure(tmp_path, monkeypatch):
    async def fake_run(args):
        return 1, "", "tunnel name already exists"

    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    with pytest.raises(RuntimeError, match="already exists"):
        await cli.create_tunnel(name="demo", cred_file=str(tmp_path / "t.json"))
```

**Step 2: 失敗。Step 3: 實作** — 追加方法:

```python
    async def create_tunnel(self, name: str, cred_file: str) -> str:
        rc, out, err = await self._run([
            "--origincert", self._origincert, "--cred-file", cred_file,
            "tunnel", "create", name,
        ])
        if rc != 0:
            raise RuntimeError(f"create tunnel failed: {err or out}")
        import json as _json
        from pathlib import Path as _Path
        data = _json.loads(_Path(cred_file).read_text())
        return data["TunnelID"]
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: create_tunnel 解析 UUID 與失敗處理"
```

### Task 3.4:`route_dns` — 帶 -f 強制建 CNAME

**Step 1: 失敗測試**(monkeypatch `_run`,斷言參數含 `-f` 與 uuid/hostname)

```python
@pytest.mark.asyncio
async def test_route_dns_passes_force_uuid_hostname(monkeypatch):
    captured = {}

    async def fake_run(args):
        captured["args"] = args
        return 0, "", ""

    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    await cli.route_dns(tunnel_uuid="u1", hostname="a.example.com")
    a = captured["args"]
    assert "route" in a and "dns" in a and "-f" in a
    assert a[-2:] == ["u1", "a.example.com"]


@pytest.mark.asyncio
async def test_route_dns_raises_on_failure(monkeypatch):
    async def fake_run(args):
        return 1, "", "zone not found"
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    with pytest.raises(RuntimeError, match="zone not found"):
        await cli.route_dns("u1", "a.example.com")
```

**Step 2: 失敗。Step 3: 實作**

```python
    async def route_dns(self, tunnel_uuid: str, hostname: str) -> None:
        rc, out, err = await self._run([
            "--origincert", self._origincert,
            "tunnel", "route", "dns", "-f", tunnel_uuid, hostname,
        ])
        if rc != 0:
            raise RuntimeError(f"route dns failed for {hostname}: {err or out}")
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: route_dns 強制建立 CNAME"
```

### Task 3.5:`ingress_validate` — 回傳 (ok, output)

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_ingress_validate_ok(monkeypatch):
    async def fake_run(args):
        assert "validate" in args
        return 0, "OK", ""
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    ok, output = await cli.ingress_validate("/data/config.json")
    assert ok is True


@pytest.mark.asyncio
async def test_ingress_validate_fail(monkeypatch):
    async def fake_run(args):
        return 1, "", "validation error: duplicated hostname"
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    ok, output = await cli.ingress_validate("/data/config.json")
    assert ok is False
    assert "duplicated" in output
```

**Step 2: 失敗。Step 3: 實作**

```python
    async def ingress_validate(self, config_path: str) -> tuple[bool, str]:
        rc, out, err = await self._run([
            "tunnel", "--config", config_path, "ingress", "validate",
        ])
        return rc == 0, (err or out)
```

**Step 4: 全檔測試**

Run: `python -m pytest tests/test_cloudflared_cli.py -v`
Expected: 全 PASS。

**Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: ingress_validate 驗證 config"
```

### Task 3.6:`login` — 啟動行程、串出 URL、等待 cert

**Step 1: 失敗測試**(monkeypatch `create_subprocess_exec` 為假行程,逐行吐 stdout,寫出 cert)

```python
import asyncio
import pytest


class _FakeProc:
    def __init__(self, lines, cert_path):
        self._lines = lines
        self._cert = cert_path
        self.returncode = None

    async def _drain(self):
        await asyncio.sleep(0)

    @property
    def stdout(self):
        async def gen():
            for ln in self._lines:
                yield ln.encode()
            # 模擬使用者完成授權後 cloudflared 寫出 cert 並結束
            from pathlib import Path
            Path(self._cert).write_text("FAKE CERT")
        return _AsyncLineReader(gen())

    async def wait(self):
        self.returncode = 0
        return 0


class _AsyncLineReader:
    def __init__(self, agen):
        self._agen = agen
    def __aiter__(self):
        return self._agen


@pytest.mark.asyncio
async def test_login_yields_url_then_writes_cert(tmp_path, monkeypatch):
    cert = tmp_path / "cert.pem"
    src_cert = tmp_path / "src_cert.pem"
    lines = [
        "Please open the following URL:\n",
        "https://dash.cloudflare.com/argotunnel?aud=x\n",
    ]

    async def fake_exec(*args, **kwargs):
        return _FakeProc(lines, src_cert)

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    cli = CloudflaredCLI()
    urls = []
    async for url in cli.login(src_cert=str(src_cert), dest_cert=str(cert)):
        urls.append(url)
    assert urls == ["https://dash.cloudflare.com/argotunnel?aud=x"]
    assert cert.read_text() == "FAKE CERT"   # 已搬到 dest
```

> 說明:`login` 設計為 async generator,先 yield 一次授權 URL,行程結束(cert 出現)後把 `~/.cloudflared/cert.pem`(此處用 src_cert 模擬)搬到 `dest_cert`。實際實作讀 stdout 逐行、用 `extract_login_url` 取 URL。

**Step 2: 失敗。Step 3: 實作**

```python
    async def login(self, src_cert: str, dest_cert: str):
        proc = await asyncio.create_subprocess_exec(
            self._binary, "tunnel", "login",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        url_sent = False
        async for raw in proc.stdout:
            line = raw.decode(errors="replace")
            if not url_sent:
                url = extract_login_url(line)
                if url:
                    url_sent = True
                    yield url
        await proc.wait()
        from pathlib import Path
        import shutil
        src = Path(src_cert)
        if src.exists():
            Path(dest_cert).parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), dest_cert)
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/cloudflared_cli.py tests/test_cloudflared_cli.py
git commit -m "feat: login async generator 串出 URL 並搬移 cert"
```

---

## Phase 4:`process_manager`(cloudflared 子行程生命週期)

取代 `podman_manager`。用 asyncio 管理 cloudflared 子行程:start / stop / restart / status / log 緩衝。**測試用真實短命令**(`sh -c "echo ...; sleep N"`)驗生命週期,不需真 cloudflared。

**Files:**
- Create: `backend/services/process_manager.py`
- Test: `tests/test_process_manager.py`

### Task 4.1:`start` 後 `is_running` 為 True;`stop` 後為 False

**Step 1: 失敗測試**

```python
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
```

**Step 2: 失敗。Step 3: 實作** — `backend/services/process_manager.py`

```python
"""Manage the cloudflared child process lifecycle (engine-agnostic)."""
import asyncio
import signal
from collections import deque
from typing import Optional


class ProcessManager:
    def __init__(self, log_buffer: int = 500):
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._args: list[str] = []
        self._logs: deque[str] = deque(maxlen=log_buffer)
        self._reader_task: Optional[asyncio.Task] = None

    def is_running(self) -> bool:
        return self._proc is not None and self._proc.returncode is None

    async def start(self, args: list[str]) -> None:
        if self.is_running():
            await self.stop()
        self._args = args
        self._proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        self._reader_task = asyncio.create_task(self._read_logs())

    async def _read_logs(self) -> None:
        assert self._proc and self._proc.stdout
        async for raw in self._proc.stdout:
            self._logs.append(raw.decode(errors="replace").rstrip("\n"))

    async def stop(self, timeout: int = 30) -> None:
        if not self._proc:
            return
        if self._proc.returncode is None:
            self._proc.send_signal(signal.SIGTERM)
            try:
                await asyncio.wait_for(self._proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                self._proc.kill()
                await self._proc.wait()
        self._proc = None

    async def restart(self) -> None:
        args = self._args
        await self.stop()
        await self.start(args)

    def recent_logs(self) -> list[str]:
        return list(self._logs)
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/process_manager.py tests/test_process_manager.py
git commit -m "feat: ProcessManager start/stop 生命週期"
```

### Task 4.2:擷取子行程 stdout 到 log 緩衝

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_captures_stdout_into_log_buffer():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "echo line-one; echo line-two; sleep 5"])
    await asyncio.sleep(0.3)   # 讓 reader 收到
    logs = pm.recent_logs()
    assert "line-one" in logs
    assert "line-two" in logs
    await pm.stop(timeout=5)
```

**Step 2: 跑驗證 → PASS(實作已含 reader)。Step 3: Commit**

```bash
git add tests/test_process_manager.py
git commit -m "test: ProcessManager 擷取 stdout"
```

### Task 4.3:`restart` 沿用相同參數重啟

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_restart_keeps_args_and_runs_again():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "sleep 30"])
    first_pid = pm._proc.pid
    await pm.restart()
    assert pm.is_running() is True
    assert pm._proc.pid != first_pid   # 是新行程
    await pm.stop(timeout=5)
```

**Step 2: PASS。Step 3: Commit**

```bash
git add tests/test_process_manager.py
git commit -m "test: ProcessManager restart 用相同參數"
```

### Task 4.4:`stop` 對已結束行程是 idempotent

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_stop_is_idempotent_on_exited_process():
    pm = ProcessManager()
    await pm.start(["sh", "-c", "exit 0"])
    await asyncio.sleep(0.2)
    await pm.stop(timeout=5)     # 不應拋例外
    assert pm.is_running() is False
    await pm.stop(timeout=5)     # 再次 stop 仍安全
    assert pm.is_running() is False
```

**Step 2: PASS。Step 3: 全檔測試**

Run: `python -m pytest tests/test_process_manager.py -v`
Expected: 全 PASS。

**Step 4: Commit**

```bash
git add tests/test_process_manager.py
git commit -m "test: ProcessManager stop idempotent"
```

### Task 4.5:`build_run_args` — 組 cloudflared 啟動參數(本地 vs token)

**Step 1: 失敗測試**

```python
from backend.services.process_manager import build_run_args


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
```

**Step 2: 失敗。Step 3: 實作** — 追加純函式:

```python
def build_run_args(
    mode: str,
    binary: str = "cloudflared",
    token: str = "",
    origincert: str = "/data/cert.pem",
    config: str = "/data/config.json",
    tunnel_name: str = "",
    post_quantum: bool = False,
    log_level: str = "info",
) -> list[str]:
    args = [binary, "tunnel", "--no-autoupdate"]
    if post_quantum:
        args.append("--post-quantum")
    if log_level and log_level != "info":
        args.extend(["--loglevel", log_level])
    if mode == "token":
        args.extend(["run", "--token", token])
    else:
        args.extend(["--origincert", origincert, "--config", config,
                     "run", tunnel_name])
    return args
```

> 註:`--post-quantum` / `--loglevel` 插在 `run` 之前(cloudflared 全域旗標需在子命令前)。測試 3 用 index 檢查即可。

**Step 4: 跑驗證**

Run: `python -m pytest tests/test_process_manager.py -k build_run_args -v`
Expected: PASS x3。

**Step 5: Commit**

```bash
git add backend/services/process_manager.py tests/test_process_manager.py
git commit -m "feat: build_run_args 組 local/token 啟動參數"
```

---

## Phase 5:`config_manager`(去 HA、加 mode / routes)

**Files:**
- Modify: `backend/services/config_manager.py`
- Test: `tests/test_config_manager.py`(更新)

### Task 5.1:新 DEFAULT_CONFIG(去 HA 欄位)

**Step 1: 失敗測試** — `tests/test_config_manager.py`

```python
import pytest
from backend.services.config_manager import ConfigManager, DEFAULT_CONFIG


def test_default_config_has_no_ha_fields():
    assert "external_hostname" not in DEFAULT_CONFIG
    assert "nginx_proxy_manager" not in DEFAULT_CONFIG
    assert DEFAULT_CONFIG["mode"] == "local"
    assert DEFAULT_CONFIG["routes"] == []
    assert DEFAULT_CONFIG["catch_all_service"] == ""
    assert DEFAULT_CONFIG["tunnel_name"] == ""
```

**Step 2: 失敗。Step 3: 改 `DEFAULT_CONFIG`**

```python
DEFAULT_CONFIG = {
    "mode": "local",                 # local | token
    "tunnel_name": "",
    "routes": [],                    # [{hostname, service, disableChunkedEncoding}]
    "catch_all_service": "",
    "post_quantum": False,
    "log_level": "info",
    "run_parameters": "",
    "no_tls_verify": True,
    "container_image": "cloudflare/cloudflared:latest",  # 保留供 e2e/相容
}
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/services/config_manager.py tests/test_config_manager.py
git commit -m "refactor: config 去 HA 化,改用 mode/routes"
```

### Task 5.2:load 對舊檔做 merge(缺鍵補預設)

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_load_merges_missing_keys(tmp_path):
    f = tmp_path / "settings.json"
    f.write_text('{"tunnel_name": "demo"}')
    mgr = ConfigManager(config_path=f)
    cfg = await mgr.load()
    assert cfg["tunnel_name"] == "demo"
    assert cfg["routes"] == []          # 補上預設
    assert cfg["mode"] == "local"
```

**Step 2: 跑驗證**(既有 `load` 已 `{**DEFAULT_CONFIG, **json}`)→ PASS。**Step 3: Commit**

```bash
git add tests/test_config_manager.py
git commit -m "test: load 補齊缺省鍵"
```

### Task 5.3:save 永不外洩 token(沿用既有保護)

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_save_strips_raw_token(tmp_path):
    f = tmp_path / "settings.json"
    mgr = ConfigManager(config_path=f)
    await mgr.save({"tunnel_token": "SECRET", "tunnel_name": "x"})
    import json
    on_disk = json.loads(f.read_text())
    assert "tunnel_token" not in on_disk
```

**Step 2: 跑驗證**(既有 `save` 已 `merged.pop("tunnel_token")`)→ PASS。**Step 3: 全檔**

Run: `python -m pytest tests/test_config_manager.py -v`
Expected: 全 PASS。

**Step 4: Commit**

```bash
git add tests/test_config_manager.py
git commit -m "test: save 不落地 raw token"
```

---

## Phase 6:Routers(setup 上線流程 + tunnel/config 改寫)

把 service 層接上 HTTP。**整合測試用 conftest 的 `client` fixture**,但要先把 conftest 從 podman mock 改成 cloudflared_cli / process_manager mock。所有 cloudflared 呼叫在此層 mock,不碰真行程。

**Files:**
- Modify: `tests/conftest.py`(換掉 podman fixture)
- Create: `backend/routers/setup.py`
- Modify: `backend/routers/tunnel.py`、`backend/main.py`
- Test: `tests/test_setup_api.py`、`tests/test_tunnel_api.py`(改寫)

### Task 6.1:改寫 conftest 的依賴注入

**Step 1:** 把 `mock_podman` fixture 換成 `mock_cli`(假 CloudflaredCLI)+ `mock_pm`(假 ProcessManager):

```python
@pytest.fixture()
def mock_cli():
    cli = MagicMock()
    async def _login(src_cert, dest_cert):
        yield "https://dash.cloudflare.com/argotunnel?aud=test"
    cli.login = _login
    cli.create_tunnel = AsyncMock(return_value="uuid-test")
    cli.route_dns = AsyncMock(return_value=None)
    cli.ingress_validate = AsyncMock(return_value=(True, "OK"))
    return cli


@pytest.fixture()
def mock_pm():
    pm = MagicMock()
    pm.is_running.return_value = True
    pm.start = AsyncMock(return_value=None)
    pm.stop = AsyncMock(return_value=None)
    pm.restart = AsyncMock(return_value=None)
    pm.recent_logs.return_value = ["log line 1"]
    return pm
```

並更新 `client` fixture 的 `patch.object`,把各 router 模組的 `cli` / `pm` / `config_mgr` 換成測試替身(移除 podman patch)。需 `from unittest.mock import AsyncMock`。

**Step 2: 跑既有測試確認沒爆**

Run: `python -m pytest -m "not e2e" --collect-only -q`
Expected: 能收集(舊的 podman 測試此任務一併刪除或標 skip)。

**Step 3: Commit**

```bash
git add tests/conftest.py
git commit -m "test: conftest 改注入 cli/pm 替身"
```

### Task 6.2:`GET /api/setup/state` 回報目前狀態

**Step 1: 失敗測試** — `tests/test_setup_api.py`

```python
import pytest


@pytest.mark.asyncio
async def test_setup_state_reports_no_cert(client, tmp_config_dir, monkeypatch):
    # cert/tunnel 檔不存在 → has_cert False
    resp = await client.get("/api/setup/state")
    assert resp.status_code == 200
    body = resp.json()
    assert body["has_cert"] is False
    assert body["has_tunnel"] is False
    assert body["mode"] in ("local", "token")
```

**Step 2: 失敗(路由不存在)。Step 3: 實作** — `backend/routers/setup.py`

```python
from pathlib import Path
from fastapi import APIRouter
from backend.models.schemas import SetupState, TunnelMode
from backend.services.config_manager import ConfigManager

router = APIRouter(prefix="/api/setup", tags=["setup"])

DATA_DIR = Path("/data")
config_mgr = ConfigManager()
cli = None   # 注入點(測試替換)
pm = None    # 注入點


@router.get("/state", response_model=SetupState)
async def get_state() -> SetupState:
    cfg = await config_mgr.load()
    cert = (DATA_DIR / "cert.pem").exists()
    tunnel_file = DATA_DIR / "tunnel.json"
    has_tunnel = tunnel_file.exists()
    uuid = None
    if has_tunnel:
        import json
        try:
            uuid = json.loads(tunnel_file.read_text()).get("TunnelID")
        except Exception:
            uuid = None
    return SetupState(
        has_cert=cert, has_tunnel=has_tunnel, tunnel_uuid=uuid,
        mode=TunnelMode(cfg.get("mode", "local")),
    )
```

在 `main.py` 加 `app.include_router(setup.router)` 並 import。測試需 monkeypatch `setup.DATA_DIR` 指向 tmp。

> 修正測試 6.2:加 `monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)` 並在 client fixture patch `setup.config_mgr`。

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/routers/setup.py backend/main.py tests/test_setup_api.py
git commit -m "feat: GET /api/setup/state"
```

### Task 6.3:`POST /api/setup/tunnel` 建立 tunnel

**Step 1: 失敗測試**

```python
@pytest.mark.asyncio
async def test_create_tunnel_endpoint_returns_uuid(client, monkeypatch, tmp_config_dir):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    resp = await client.post("/api/setup/tunnel", json={"tunnel_name": "demo"})
    assert resp.status_code == 200
    assert resp.json()["tunnel_uuid"] == "uuid-test"   # 來自 mock_cli
```

**Step 2: 失敗。Step 3: 實作** — 加路由:

```python
from pydantic import BaseModel


class CreateTunnelReq(BaseModel):
    tunnel_name: str


@router.post("/tunnel")
async def create_tunnel(req: CreateTunnelReq):
    cred = str(DATA_DIR / "tunnel.json")
    uuid = await cli.create_tunnel(name=req.tunnel_name, cred_file=cred)
    cfg = await config_mgr.load()
    cfg["tunnel_name"] = req.tunnel_name
    await config_mgr.save(cfg)
    return {"tunnel_uuid": uuid}
```

**Step 4: PASS。Step 5: Commit**

```bash
git add backend/routers/setup.py tests/test_setup_api.py
git commit -m "feat: POST /api/setup/tunnel 建立 tunnel"
```

### Task 6.4:`POST /api/setup/apply` — build→validate→dns→restart

**Step 1: 失敗測試(成功路徑 + 驗證失敗路徑)**

```python
@pytest.mark.asyncio
async def test_apply_success_builds_validates_dns_restarts(
    client, monkeypatch, tmp_config_dir
):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    payload = {"routes": [{"hostname": "a.example.com",
                           "service": "http://localhost:8080"}],
               "catch_all_service": ""}
    resp = await client.post("/api/setup/apply", json=payload)
    assert resp.status_code == 200
    assert resp.json()["status"] == "applied"
    # config.json 已寫出
    assert (tmp_config_dir / "config.json").exists()


@pytest.mark.asyncio
async def test_apply_fails_when_ingress_invalid(
    client, mock_cli, monkeypatch, tmp_config_dir
):
    monkeypatch.setattr("backend.routers.setup.DATA_DIR", tmp_config_dir)
    (tmp_config_dir / "tunnel.json").write_text('{"TunnelID": "uuid-test"}')
    mock_cli.ingress_validate.return_value = (False, "duplicated hostname")
    resp = await client.post("/api/setup/apply",
        json={"routes": [{"hostname": "a", "service": "s"}]})
    assert resp.status_code == 422
    assert "duplicated" in resp.json()["detail"]
```

**Step 2: 失敗。Step 3: 實作** — 加路由(串接 config_builder + cli + pm):

```python
from fastapi import HTTPException
from backend.services.config_builder import build_ingress_config, write_config_json
from backend.services.process_manager import build_run_args


class ApplyReq(BaseModel):
    routes: list[dict] = []
    catch_all_service: str = ""


@router.post("/apply")
async def apply(req: ApplyReq):
    import json
    tunnel_file = DATA_DIR / "tunnel.json"
    if not tunnel_file.exists():
        raise HTTPException(400, "尚未建立 tunnel")
    uuid = json.loads(tunnel_file.read_text())["TunnelID"]

    cfg = await config_mgr.load()
    config = build_ingress_config(
        tunnel_uuid=uuid,
        credentials_file=str(tunnel_file),
        routes=req.routes,
        catch_all_service=req.catch_all_service or None,
        no_tls_verify=cfg.get("no_tls_verify", True),
    )
    config_path = DATA_DIR / "config.json"
    write_config_json(config, config_path)

    ok, output = await cli.ingress_validate(str(config_path))
    if not ok:
        raise HTTPException(422, f"ingress 驗證失敗:{output}")

    for r in req.routes:
        await cli.route_dns(uuid, r["hostname"])

    cfg["routes"] = req.routes
    cfg["catch_all_service"] = req.catch_all_service
    await config_mgr.save(cfg)

    args = build_run_args(mode="local", origincert=str(DATA_DIR / "cert.pem"),
                          config=str(config_path),
                          tunnel_name=cfg.get("tunnel_name", ""),
                          post_quantum=cfg.get("post_quantum", False),
                          log_level=cfg.get("log_level", "info"))
    await pm.restart() if pm.is_running() else await pm.start(args)
    return {"status": "applied", "route_count": len(req.routes)}
```

**Step 4: 跑兩個測試 → PASS。Step 5: Commit**

```bash
git add backend/routers/setup.py tests/test_setup_api.py
git commit -m "feat: POST /api/setup/apply 全鏈(build/validate/dns/restart)"
```

### Task 6.5:`WS /api/setup/login` — 串出授權 URL

**Step 1: 失敗測試**(用 httpx/starlette TestClient 的 websocket;或退而測底層 generator 已於 3.6 覆蓋,此處測 router 把 URL 寫到 WS)

```python
@pytest.mark.asyncio
async def test_login_ws_streams_url(client):
    # 使用 starlette TestClient 的同步 websocket
    from backend.main import app
    from starlette.testclient import TestClient
    with TestClient(app).websocket_connect("/api/setup/login") as ws:
        msg = ws.receive_json()
        assert msg["type"] == "url"
        assert msg["url"].startswith("https://dash.cloudflare.com/argotunnel")
```

> 註:WS 不走 CSRF(main.py 已 bypass)。需在 setup.router 注入 mock_cli.login。

**Step 2: 失敗。Step 3: 實作** — 加 WebSocket 路由:

```python
from fastapi import WebSocket


@router.websocket("/login")
async def login_ws(ws: WebSocket):
    await ws.accept()
    src = "/root/.cloudflared/cert.pem"
    dest = str(DATA_DIR / "cert.pem")
    try:
        async for url in cli.login(src_cert=src, dest_cert=dest):
            await ws.send_json({"type": "url", "url": url})
        await ws.send_json({"type": "done"})
    finally:
        await ws.close()
```

**Step 4: PASS。Step 5: 全 Phase 6 測試**

Run: `python -m pytest tests/test_setup_api.py -v`
Expected: 全 PASS。

**Step 6: Commit**

```bash
git add backend/routers/setup.py tests/test_setup_api.py
git commit -m "feat: WS /api/setup/login 串出授權 URL"
```

### Task 6.6:改寫 `tunnel.py` 啟停走 process_manager

**Step 1: 失敗測試** — `tests/test_tunnel_api.py`

```python
@pytest.mark.asyncio
async def test_tunnel_stop_calls_pm(client, mock_pm):
    resp = await client.post("/api/tunnel/stop")
    assert resp.status_code == 200
    mock_pm.stop.assert_awaited_once()


@pytest.mark.asyncio
async def test_tunnel_status_running(client, mock_pm):
    resp = await client.get("/api/tunnel/status")
    assert resp.json()["running"] is True
```

**Step 2: 失敗。Step 3: 改 `tunnel.py`**(移除 podman,改用注入的 `pm`;status 回 `{"running": pm.is_running()}`,stop/start/restart 對應)。

**Step 4: PASS。Step 5: 移除 `podman_manager.py` 與其測試**

```bash
git rm backend/services/podman_manager.py tests/test_config_api.py
```
(`test_config_api.py` 若依賴 podman 則刪;若仍適用則改注入。)

**Step 6: 全測試綠燈**

Run: `python -m pytest -m "not e2e" -v`
Expected: 全 PASS,無 import podman 殘留。

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor: tunnel router 改用 process_manager,移除 podman 層"
```

---

## Phase 7:Dockerfile / compose(單容器 + cloudflared binary)

把 cloudflared 二進位裝進 GUI image,改成單容器、掛一個 `/data` volume,docker/podman 通用。

### Task 7.1:多階段 Dockerfile 加入 cloudflared 二進位

**Files:**
- Modify: `Dockerfile`

**Step 1:** 在最終 runtime stage 加入(用官方 release 二進位,依架構):

```dockerfile
# --- cloudflared 二進位 ---
ARG TARGETARCH
ARG CLOUDFLARED_VERSION=2026.6.1
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) CF_ARCH=amd64 ;; \
      arm64) CF_ARCH=arm64 ;; \
      *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}"; \
    chmod +x /usr/local/bin/cloudflared; \
    cloudflared --version
```

並確保 `VOLUME ["/data"]`、entrypoint 啟動 uvicorn。

**Step 2: 建置驗證(本機)**

Run: `docker build -t cf-webui:test .`
Expected: 成功,且 build log 顯示 `cloudflared version 2026.x`。
(若用 podman:`podman build -t cf-webui:test .`,結果應一致。)

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "build: image 內建 cloudflared 二進位(多架構)"
```

### Task 7.2:單容器 compose + /data volume

**Files:**
- Modify: `docker-compose.yml`

**Step 1:** 改成單一服務、無 podman socket 掛載:

```yaml
services:
  cf-tunnel-webgui:
    image: cf-webui:latest
    container_name: cf-tunnel-webgui
    build: .
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - cf_data:/data
    environment:
      - CSRF_SECRET=${CSRF_SECRET:-}
volumes:
  cf_data:
```

**Step 2: 啟動煙霧測試**

Run: `docker compose up -d && sleep 3 && curl -fsS http://localhost:8888/api/health`
Expected: 回 `{"status":"ok",...}`。
Run（podman 對照）: `podman run -d -p 8888:8888 -v cf_data:/data cf-webui:test` 後同樣 `curl /api/health` 成功 → 證明通用。

**Step 3: 收尾並 Commit**

```bash
docker compose down
git add docker-compose.yml
git commit -m "build: 單容器 compose,docker/podman 通用,掛 /data"
```

### Task 7.3:更新 README(部署與自助流程)

**Files:** Modify `README.md` / `README_zh-TW.md`

**Step 1:** 改寫安裝段:`docker run`/`podman run` 同指令、`/data` 說明、login 自助流程、token 模式與本地模式選擇、刪路由需手動刪 DNS 的提醒。

**Step 2: Commit**

```bash
git add README.md README_zh-TW.md
git commit -m "docs: 更新部署與自助流程說明"
```

---

## Phase 8:前端(上線精靈 + 路由編輯器)

沿用 Vue3 + Pinia + 既有 CSRF/WebSocket composable。新增精靈頁與路由編輯器。前端測試用 **Vitest**。

> 前置:`cd frontend && npm i -D vitest @vue/test-utils jsdom` 並在 `vite.config.ts` 加 `test` 設定(`environment: 'jsdom'`)。

### Task 8.1:Pinia setup store(狀態查詢 + apply)

**Files:**
- Create: `frontend/src/stores/setup.ts`
- Test: `frontend/src/stores/__tests__/setup.spec.ts`

**Step 1: 失敗測試**(mock fetch /api/setup/state)

```ts
import { setActivePinia, createPinia } from 'pinia'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useSetupStore } from '../setup'

describe('setup store', () => {
  beforeEach(() => setActivePinia(createPinia()))
  it('fetchState 寫入 hasCert/hasTunnel', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ has_cert: true, has_tunnel: false,
                           tunnel_uuid: null, mode: 'local' }),
    }))
    const s = useSetupStore()
    await s.fetchState()
    expect(s.hasCert).toBe(true)
    expect(s.hasTunnel).toBe(false)
  })
})
```

**Step 2: 失敗。Step 3: 實作 store**(`fetchState` / `createTunnel` / `apply`,呼叫對應 API、帶 CSRF header)。

**Step 4: 跑** `cd frontend && npx vitest run src/stores/__tests__/setup.spec.ts`：PASS。

**Step 5: Commit**

```bash
git add frontend/src/stores/setup.ts frontend/src/stores/__tests__/setup.spec.ts frontend/vite.config.ts frontend/package.json
git commit -m "feat(web): setup store + vitest"
```

### Task 8.2:路由編輯器元件(增刪列、驗證)

**Files:**
- Create: `frontend/src/components/RouteEditor.vue`
- Test: `frontend/src/components/__tests__/RouteEditor.spec.ts`

**Step 1: 失敗測試**(掛載元件、點「新增」→ 多一列;填非法 hostname → 顯示錯誤;emit `update:routes`)。

**Step 2: 失敗。Step 3: 實作元件**(v-model routes、前端先做與後端一致的 hostname regex 預檢)。

**Step 4: 跑 Vitest → PASS。Step 5: Commit**

```bash
git add frontend/src/components/RouteEditor.vue frontend/src/components/__tests__/RouteEditor.spec.ts
git commit -m "feat(web): RouteEditor 路由增刪與前端驗證"
```

### Task 8.3:上線精靈頁(A→B→C→D 狀態機)

**Files:**
- Create: `frontend/src/pages/SetupWizard.vue`
- Modify: `frontend/src/router.ts`
- Test: `frontend/src/pages/__tests__/SetupWizard.spec.ts`

**Step 1: 失敗測試**(依 store 狀態渲染對應步驟:無 cert → 顯示「連結帳號 + 授權 URL」;有 cert 無 tunnel → 顯示建立 tunnel;有 tunnel → 顯示 RouteEditor)。

**Step 2: 失敗。Step 3: 實作頁面**:
- 步驟 A:按鈕開 WS `/api/setup/login`,收到 `{type:'url'}` 顯示連結 + QR,輪詢 `fetchState` 直到 `has_cert`。
- 步驟 B:輸入 tunnel 名稱 → `createTunnel`。
- 步驟 C:`RouteEditor` + 「套用」→ `apply`,顯示驗證錯誤。
- 步驟 D:狀態 + LogViewer(沿用既有元件)。

**Step 4: 跑 Vitest → PASS。Step 5: Commit**

```bash
git add frontend/src/pages/SetupWizard.vue frontend/src/router.ts frontend/src/pages/__tests__/SetupWizard.spec.ts
git commit -m "feat(web): 上線精靈狀態機頁"
```

### Task 8.4:前端建置驗證

**Step 1:** Run `cd frontend && npx vitest run`(全綠)+ `npm run build`(成功產 dist)。

**Step 2: Commit**(若有 lint/型別修正)

```bash
git add -A
git commit -m "chore(web): 前端建置與測試綠燈"
```

---

## Phase 9:整合 / e2e 煙霧測試

`@pytest.mark.e2e`,預設 deselect,只在有真實 Cloudflare 憑證的環境手動跑。

### Task 9.1:容器健康與 setup state e2e

**Files:** Modify `tests/test_e2e_live.py`

**Step 1:** 加(對 `CF_TEST_URL` 跑):

```python
import os, httpx, pytest


@pytest.mark.e2e
@pytest.mark.enable_socket
def test_health_live(live_base_url):
    r = httpx.get(f"{live_base_url}/api/health", timeout=5)
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.e2e
@pytest.mark.enable_socket
def test_setup_state_live(live_base_url):
    r = httpx.get(f"{live_base_url}/api/setup/state", timeout=5)
    assert r.status_code == 200
    assert "has_cert" in r.json()
```

**Step 2: 本機跑(需先 `docker compose up -d`)**

Run: `CF_TEST_URL=http://localhost:8888 python -m pytest -m e2e -v`
Expected: PASS。

**Step 3: Commit**

```bash
git add tests/test_e2e_live.py
git commit -m "test: e2e 健康與 setup state 煙霧測試"
```

### Task 9.2:全套件最終驗證

**Step 1:** Run `python -m pytest -m "not e2e" -v`(後端全綠)。
**Step 2:** Run `cd frontend && npx vitest run`(前端全綠)。
**Step 3:** Run `docker build .` 與 `podman build .` 皆成功。
**Step 4:** 手動跑一次本地管理完整流程(login→create→apply),確認 tunnel 連線、hostname 可達。
**Step 5: 最終 Commit / 開 PR**

```bash
git add -A && git commit -m "chore: 通用本地管理版 MVP 完成"
```

---

## 完成定義(Definition of Done)

- [ ] `python -m pytest -m "not e2e"` 全綠,核心 service 行覆蓋 ~100%。
- [ ] 前端 `vitest run` 全綠。
- [ ] `docker build` 與 `podman build` 皆成功,同一 image 兩引擎 `run` 起來 `/api/health` 皆 200。
- [ ] 無 `podman` SDK 依賴殘留(`grep -r "from podman" backend` 無結果)。
- [ ] 本地管理流程可端到端跑通:授權→建 tunnel→設路由→DNS→連線。
- [ ] token 模式仍可直通運行。
- [ ] README 反映新部署方式與自助流程。

## 風險與緩解(實作時注意)

| 風險 | 緩解 |
|---|---|
| `cloudflared tunnel login` 互動性難測 | 已抽 `extract_login_url` 純函式 + 假行程測 generator;真流程留 e2e |
| WS 在 TestClient 的 async/sync 差異 | 用 starlette `TestClient`(同步 WS)測 router,底層 generator 另以 asyncio 測 |
| 多架構二進位下載失敗 | Dockerfile 固定 `CLOUDFLARED_VERSION`,build 時 `--version` 驗證 |
| 刪路由不會刪 DNS | UI 明確提示;DoD 不含自動刪 DNS(YAGNI,列為後續) |
| cert.pem 權限敏感 | 存 /data,README 提醒;不寫入 settings.json |

