from pydantic import BaseModel, Field, field_validator
from enum import Enum
from typing import Optional
import re


class LogLevel(str, Enum):
    debug = "debug"
    info = "info"
    warn = "warn"
    error = "error"
    fatal = "fatal"


class TunnelConfigRead(BaseModel):
    """Response model for GET /api/config — token is always masked."""

    tunnel_token_secret: str = Field(description="Podman secret name holding the token")
    tunnel_token_masked: str = Field(description="Masked token value")
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    extra_args: str = ""
    container_name: str = "cloudflared"
    container_image: str = "cloudflare/cloudflared:latest"


class TunnelConfigWrite(BaseModel):
    """Request model for PUT /api/config."""

    tunnel_token: Optional[str] = Field(
        None, description="Raw token. If null/empty, existing secret is kept."
    )
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    extra_args: str = ""
    container_name: str = "cloudflared"
    container_image: str = "cloudflare/cloudflared:latest"

    @field_validator("extra_args")
    @classmethod
    def validate_extra_args(cls, v: str) -> str:
        if re.search(r"[;&|`$(){}]", v):
            raise ValueError("extra_args contains disallowed shell characters")
        return v.strip()

    @field_validator("container_name")
    @classmethod
    def validate_container_name(cls, v: str) -> str:
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", v):
            raise ValueError("Invalid container name")
        return v


class ContainerStatus(str, Enum):
    running = "running"
    stopped = "stopped"
    exited = "exited"
    created = "created"
    paused = "paused"
    restarting = "restarting"
    removing = "removing"
    dead = "dead"
    not_found = "not_found"
    unknown = "unknown"


class TunnelStatusResponse(BaseModel):
    status: ContainerStatus
    container_id: Optional[str] = None
    image: Optional[str] = None
    started_at: Optional[str] = None
    uptime_seconds: Optional[int] = None
    restart_count: int = 0
    exit_code: Optional[int] = None


class ActionResponse(BaseModel):
    success: bool
    message: str
    container_id: Optional[str] = None


class HealthResponse(BaseModel):
    status: str = "ok"
    podman_connected: bool
    tunnel_status: ContainerStatus
