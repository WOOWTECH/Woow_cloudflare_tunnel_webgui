from fastapi import APIRouter, HTTPException

from ..models.schemas import TunnelConfigRead, TunnelConfigWrite, LogLevel
from ..services.config_manager import ConfigManager
from ..services.podman_manager import PodmanManager
from ..services.validator import validate_image, validate_tunnel_token

router = APIRouter(prefix="/api/config", tags=["config"])
config_mgr = ConfigManager()
podman_mgr = PodmanManager()


@router.get("", response_model=TunnelConfigRead)
async def get_config():
    cfg = await config_mgr.load()
    secret_name = cfg.get("tunnel_token_secret", "cf-tunnel-token")
    token_masked = podman_mgr.secret_get_masked(secret_name)
    return TunnelConfigRead(
        tunnel_token_secret=secret_name,
        tunnel_token_masked=token_masked,
        post_quantum=cfg.get("post_quantum", False),
        log_level=LogLevel(cfg.get("log_level", "info")),
        extra_args=cfg.get("extra_args", ""),
        container_name=cfg.get("container_name", "cloudflared"),
        container_image=cfg.get("container_image", "cloudflare/cloudflared:latest"),
    )


@router.put("", response_model=TunnelConfigRead)
async def update_config(body: TunnelConfigWrite):
    if not validate_image(body.container_image):
        raise HTTPException(400, "Only cloudflare/cloudflared images are allowed")

    cfg = await config_mgr.load()
    secret_name = cfg.get("tunnel_token_secret", "cf-tunnel-token")

    # Update podman secret if a new token is provided
    if body.tunnel_token:
        if not validate_tunnel_token(body.tunnel_token):
            raise HTTPException(400, "Invalid tunnel token format")
        podman_mgr.secret_set(secret_name, body.tunnel_token)

    new_cfg = await config_mgr.save(
        {
            "tunnel_token_secret": secret_name,
            "post_quantum": body.post_quantum,
            "log_level": body.log_level.value,
            "extra_args": body.extra_args,
            "container_name": body.container_name,
            "container_image": body.container_image,
        }
    )

    token_masked = podman_mgr.secret_get_masked(secret_name)
    return TunnelConfigRead(
        tunnel_token_secret=secret_name,
        tunnel_token_masked=token_masked,
        post_quantum=new_cfg["post_quantum"],
        log_level=LogLevel(new_cfg["log_level"]),
        extra_args=new_cfg["extra_args"],
        container_name=new_cfg["container_name"],
        container_image=new_cfg["container_image"],
    )
