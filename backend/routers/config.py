from fastapi import APIRouter

from ..models.schemas import TunnelConfigRead, TunnelConfigWrite, LogLevel, TunnelMode
from ..services.instances import config_mgr, token_store

router = APIRouter(prefix="/api/config", tags=["config"])


def _to_read(cfg: dict) -> TunnelConfigRead:
    return TunnelConfigRead(
        mode=TunnelMode(cfg.get("mode", "local")),
        tunnel_name=cfg.get("tunnel_name", ""),
        routes=cfg.get("routes", []),
        catch_all_service=cfg.get("catch_all_service", ""),
        post_quantum=cfg.get("post_quantum", False),
        log_level=LogLevel(cfg.get("log_level", "info")),
        run_parameters=cfg.get("run_parameters", ""),
        no_tls_verify=cfg.get("no_tls_verify", True),
        tunnel_token_masked=token_store.get_masked(),
    )


@router.get("", response_model=TunnelConfigRead)
async def get_config():
    cfg = await config_mgr.load()
    return _to_read(cfg)


@router.put("", response_model=TunnelConfigRead)
async def update_config(body: TunnelConfigWrite):
    # Persist a new token to the file-backed store (never into settings.json)
    if body.tunnel_token:
        token_store.set(body.tunnel_token)

    new_cfg = await config_mgr.save(
        {
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
    return _to_read(new_cfg)
