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
        external_hostname=cfg.get("external_hostname", ""),
        additional_hosts=cfg.get("additional_hosts", []),
        tunnel_name=cfg.get("tunnel_name", ""),
        catch_all_service=cfg.get("catch_all_service", ""),
        nginx_proxy_manager=cfg.get("nginx_proxy_manager", False),
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
            "external_hostname": body.external_hostname,
            "additional_hosts": [h.model_dump() for h in body.additional_hosts],
            "tunnel_name": body.tunnel_name,
            "catch_all_service": body.catch_all_service,
            "nginx_proxy_manager": body.nginx_proxy_manager,
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
        external_hostname=new_cfg["external_hostname"],
        additional_hosts=new_cfg["additional_hosts"],
        tunnel_name=new_cfg["tunnel_name"],
        catch_all_service=new_cfg["catch_all_service"],
        nginx_proxy_manager=new_cfg["nginx_proxy_manager"],
    )
