# Cloudflare Tunnel Web GUI — 通用本地管理版 設計文件

- 日期:2026-06-27
- 分支:`feat/local-managed-generic`
- 狀態:設計定稿(待實作)

## 1. 目標與前提

把 `Woow_cloudflare_tunnel_webgui` 從「cloudflared 容器啟停面板」升級成
**通用的 Cloudflare Tunnel 設定工具**,讓「已申請 CF tunnel 的使用者,設定自己 tunnel 的內容」。

核心前提(不可違背):

- **使用者視角,非管理員視角。** 工具用使用者**自己 tunnel 的憑證**設定自己的 tunnel,
  **不需要、也不使用** 管理員級的 Cloudflare API Token。
- **通用部署。** 同一個 image 能在 **Docker 與 Podman** 上以相同方式部署,無引擎專屬程式碼。
- **對齊** `homeassistant-apps/app-cloudflared` 的設定模型與自助流程(「基本一樣」),
  但移除 Home Assistant 專屬邏輯。

## 2. 為什麼是「本地管理 + cert.pem 自助授權」

| | 遠端管理(token 模式) | 本地管理(config.yml) |
|---|---|---|
| 設定存放 | Cloudflare 雲端 | 使用者機器上的 config.json |
| 改設定需要 | Dashboard 或 **admin API Token** | 使用者自己編 config |
| 符合前提? | ❌ 需管理員級權限 | ✅ 純自助 |
| 憑證 | 另申請 admin API Token | `cloudflared tunnel login` 取得的 cert.pem(使用者自己瀏覽器授權自己的 zone) |

已查證(cloudflared #633 / #1029):token 模式下本地 config 會被忽略,
故「設定自己 tunnel 內容」只能走本地管理。憑證用 cert.pem 自助授權,完全不碰管理員 API。

## 3. 架構:單一容器 + 子行程

```
┌─ 單一容器 (FastAPI + Vue + cloudflared binary) ─────────────┐
│                                                              │
│  Web GUI (FastAPI)                                           │
│    ├── 產生設定檔 ──► /data/{cert.pem, tunnel.json, config.json}
│    ├── ProcessManager ──► cloudflared (asyncio subprocess)   │
│    │      start / stop / restart / 讀 stdout                  │
│    └── WebSocket ──► 串流 cloudflared log + login URL          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
   部署:docker run / podman run 同一 image,掛一個 /data volume → 完全一致
```

- **取代** 現有 `podman_manager.py`(Podman SDK 層)為 `process_manager.py`(asyncio 子行程)。
- GUI 容器內建 cloudflared CLI,直接以 subprocess 跑
  `login` / `create` / `route dns` / `ingress validate` / `run`。
- 無 docker/podman socket 依賴 → 真正通用、無高權限攻擊面。
- 與 HA add-on 的單容器模型一致。

### 兩種運行模式(token 優先,沿用 add-on 行為)

- **有 `tunnel_token`** → `cloudflared tunnel run --token=...`,其餘設定忽略(remote)。
- **無 token** → 本地管理:依下方自助流程產檔後
  `cloudflared tunnel --origincert=/data/cert.pem --config=/data/config.json run <name>`。

## 4. 設定 Schema(沿用 + 去 HA 化)

保留欄位:`additional_hosts[]`(`hostname` / `service` / `disableChunkedEncoding`)、
`tunnel_name`、`catch_all_service`、`post_quantum`、`run_parameters`、`log_level`、`tunnel_token`。

去 HA 化改動:

- **移除** `external_hostname` 對 `homeassistant:8123` 的自動偵測與讀取
  `/homeassistant/configuration.yaml`。所有路由統一為 `additional_hosts` 的
  `hostname → service`(service 由使用者填完整 URL)。
- **移除** `nginx_proxy_manager`(HA addon slug 專屬);catch-all 一律用通用的 `catch_all_service` URL,
  未設則 `http_status:404`。
- 全域 `originRequest.noTLSVerify: true`(沿用 add-on 預設,之後可做成可選)。

## 5. 自助上線精靈(新 UX 核心)

Web GUI 以狀態機帶使用者走完 add-on 在背景做的事:

| 狀態 | 畫面 | 後端動作 |
|---|---|---|
| **A 未授權**(無 cert.pem) | 「連結 Cloudflare 帳號」→ 顯示授權 URL(+ QR) | 跑 `cloudflared tunnel login`,擷取 stdout 的 URL 推前端;輪詢偵測 `/data/cert.pem` |
| **B 未建 tunnel** | 填 tunnel 名稱 → 建立 | `cloudflared tunnel create <name>` → tunnel.json(含 TunnelID);若同名已存在則提示 |
| **C 設定路由** | 路由編輯器:多筆 hostname→service、disableChunkedEncoding、catch-all | 產 config.json → `ingress validate` → 每個 host `route dns -f <uuid> <host>` → 重啟 cloudflared |
| **D 運作中** | 狀態儀表板 + 即時 log | 顯示連線狀態 / per-route |

關鍵新件:**「授權 URL 顯示 + 輪詢 cert.pem」** 是 HA 環境免費、Web GUI 要自己實作的流程。

## 6. config.json 產生邏輯(port 自 add-on `createConfig`)

```
{
  "tunnel": "<uuid>",
  "credentials-file": "/data/tunnel.json",
  "ingress": [
    { "hostname": "<host>", "service": "<url>",
      "originRequest": { "disableChunkedEncoding": <bool>, "noTLSVerify": true } },
    ... (每筆 additional_hosts)
    { "service": "<catch_all_service 或 http_status:404>",
      "originRequest": { "noTLSVerify": true } }
  ]
}
```

- ingress 必須以 catch-all（只有 `service`）結尾。
- 寫檔後跑 `cloudflared tunnel --config=... ingress validate` 驗證,失敗則不啟動。

## 7. 後端要新增 / 改動的檔案

| 檔案 | 動作 | 說明 |
|---|---|---|
| `services/cloudflared_cli.py` | **新增** | async 包裝 subprocess:login(串流 URL)/ create / list / route dns / ingress validate |
| `services/config_builder.py` | **新增** | 設定欄位 → config.json(ingress / originRequest / catch-all / noTLSVerify)|
| `services/process_manager.py` | **新增(取代 podman_manager)** | asyncio 管理 cloudflared 子行程:start/stop/restart/狀態/log |
| `services/config_manager.py` | 改 | 擴充 schema:路由清單 + `mode`(local/token);去 HA 欄位 |
| `models/schemas.py` | 改 | 路由模型、setup 狀態、login 流程的 request/response |
| `routers/setup.py` | **新增** | `/api/setup/login`(start+poll)、`/api/setup/tunnel`(create)、`/api/setup/apply`(build+validate+dns+restart)|
| `routers/tunnel.py` | 改 | 啟停改走 process_manager;狀態回報 |
| `routers/podman_*`、`services/podman_manager.py` | **移除** | Podman SDK 層整個拿掉 |
| `Dockerfile` | 改 | 安裝 cloudflared 二進位到 image;單容器 entrypoint |
| `docker-compose.yml` | 改 | 單服務 + 一個 /data volume;標註 docker/podman 皆可 |
| 前端 `pages/` `components/` | 改/增 | 上線精靈(A–D 狀態)、路由編輯器;沿用 CSRF / WebSocket / log viewer |

骨架沿用:FastAPI app、CSRF、CORS、WebSocket、log viewer、Vue3 SPA、Pinia stores。

## 8. MVP 範圍(= ingress 路由 + 自動 DNS)

**納入:** 授權精靈(login + 偵測 cert)、tunnel 建立/沿用、路由編輯器
(hostname→service + disableChunkedEncoding + catch-all/404)、config.json 產生 + 驗證、
`route dns` 自動建 CNAME、本地管理模式運行、狀態與即時 log、token 模式相容(直通)。

**暫不做(後續):** private network / WARP routing、Access application/policy、virtual network、
多 tunnel 管理、wildcard DNS 進階、noTLSVerify 細項可選。

## 9. 風險與待確認

- **login 互動性:** `cloudflared tunnel login` 為瀏覽器流程,需穩定擷取 stdout/stderr 的 URL 並輪詢 cert.pem;逾時要可重試。
- **DNS 刪除:** 刪路由不會刪 CNAME(add-on 同此限制)→ UI 需明確提示使用者自行至 Cloudflare 刪。
- **route dns -f 會覆寫** 既有同名 DNS → 套用前提示確認。
- **cert.pem 權限:** 為使用者帳號級憑證,存於 /data volume,需文件提醒妥善保管(這是使用者自己的)。
- **單容器內 cloudflared 崩潰** 需被 process_manager 偵測並可重啟 / 回報狀態。

## 10. 部署目標一致性

```bash
# Docker 與 Podman 完全相同
docker run -d --name cf-tunnel-webgui -p 8888:8888 -v cf_data:/data <image>
podman run -d --name cf-tunnel-webgui -p 8888:8888 -v cf_data:/data <image>
```

無 socket 掛載、無引擎專屬參數 → 達成「通用部署」。
