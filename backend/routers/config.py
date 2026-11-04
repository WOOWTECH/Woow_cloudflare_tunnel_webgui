"""GET/PUT /api/config.

PUT semantics for tunnel_token (same as the HA add-on's options):
- omitted or null → keep the stored token
- ""              → remove it
- a value         → replace it (normalize_tunnel_token extracts it from a
                    pasted install command)

?restart=true applies the saved settings immediately: a fresh cloudflared argv
and, in local mode, a regenerated ingress config (services/runtime.py).
"""
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query

from ..models.schemas import TunnelConfigRead, TunnelConfigWrite, TunnelMode
from ..services import runtime
from ..services.instances import cli, config_mgr, pm, token_store
from . import paas

router = APIRouter(prefix="/api/config", tags=["config"])

DATA_DIR = Path("/data")


def _to_read(cfg: dict) -> TunnelConfigRead:
    return TunnelConfigRead(
        mode=TunnelMode(cfg.get("mode", "local")),
        tunnel_name=cfg.get("tunnel_name", ""),
        routes=cfg.get("routes", []),
        catch_all_service=cfg.get("catch_all_service", ""),
        post_quantum=cfg.get("post_quantum", False),
        log_level=cfg.get("log_level", "info"),
        run_parameters=cfg.get("run_parameters", []),
        no_tls_verify=cfg.get("no_tls_verify", True),
        tunnel_token_masked=token_store.get_masked(),
        tunnel_token_set=token_store.has(),
        tunnel_token_managed_by_paas=paas.managed_by_paas(),
    )


@router.get("", response_model=TunnelConfigRead)
async def get_config():
    cfg = await config_mgr.load()
    return _to_read(cfg)


@router.put("", response_model=TunnelConfigRead)
async def update_config(
    body: TunnelConfigWrite,
    restart: bool = Query(default=False, description="Apply the saved settings now."),
):
    async with paas.lock:
        return await _save(body, restart)


async def _save(body: TunnelConfigWrite, restart: bool) -> TunnelConfigRead:
    paas_state = paas._state()
    if paas_state.get("release_pending"):
        raise HTTPException(409, "正在解除 PaaS 綁定;請到 PaaS 連結頁完成後再修改設定")
    if paas_state.get("connection"):
        if body.tunnel_token is not None:
            raise HTTPException(409, "Tunnel 憑證由 PaaS 管理;請先到 PaaS 連結頁停止連線並解除綁定")
        if body.mode != TunnelMode.token:
            raise HTTPException(409, "PaaS 連線使用 token 模式;要改用 local 模式請先到 PaaS 連結頁解除綁定")

    will_have_token = token_store.has() if body.tunnel_token is None else bool(body.tunnel_token)
    if body.mode == TunnelMode.token and not will_have_token:
        raise HTTPException(422, "token 模式需要 tunnel token:請貼上 token,或改用 local 模式")

    current = await config_mgr.load()
    if body.tunnel_token == "":
        token_store.clear()
    elif body.tunnel_token:
        token_store.set(body.tunnel_token)

    new_cfg = await config_mgr.save(
        {
            **current,
            "mode": body.mode.value,
            "tunnel_name": body.tunnel_name,
            "routes": [r.model_dump() for r in body.routes],
            "catch_all_service": body.catch_all_service,
            "post_quantum": body.post_quantum,
            "log_level": body.log_level.value,
            "run_parameters": body.run_parameters,
            "no_tls_verify": body.no_tls_verify,
        }
    )
    if restart:
        try:
            await runtime.apply(pm, config_mgr, token_store, cli, DATA_DIR)
        except runtime.TunnelStartError as exc:
            raise HTTPException(exc.status, f"設定已儲存,但無法套用:{exc.message}") from exc
        new_cfg = await config_mgr.load()
    return _to_read(new_cfg)
