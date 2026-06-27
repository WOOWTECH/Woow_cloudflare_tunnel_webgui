from pydantic import BaseModel, Field, field_validator
from enum import Enum
from typing import Optional, List
import re


class LogLevel(str, Enum):
    trace = "trace"
    debug = "debug"
    info = "info"
    notice = "notice"
    warn = "warn"
    warning = "warning"
    error = "error"
    fatal = "fatal"


class TunnelMode(str, Enum):
    local = "local"
    token = "token"


class AdditionalHost(BaseModel):
    hostname: str = Field(description="Public hostname for this route")
    service: str = Field(description="Local service URL, e.g. http://localhost:8080")
    disableChunkedEncoding: bool = Field(
        default=False,
        description="Disable chunked transfer encoding for this host",
    )

    @field_validator("hostname")
    @classmethod
    def validate_hostname(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Hostname cannot be empty")
        return v

    @field_validator("service")
    @classmethod
    def validate_service(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Service URL cannot be empty")
        return v


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


class TunnelConfigRead(BaseModel):
    """Response model for GET /api/config — token is always masked."""

    tunnel_token_secret: str = Field(description="Podman secret name holding the token")
    tunnel_token_masked: str = Field(description="Masked token value")
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    extra_args: str = ""
    container_name: str = "cloudflared"
    container_image: str = "cloudflare/cloudflared:latest"
    # HAOS-matching fields
    external_hostname: str = ""
    additional_hosts: List[AdditionalHost] = []
    tunnel_name: str = ""
    catch_all_service: str = ""
    nginx_proxy_manager: bool = False


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
    # HAOS-matching fields
    external_hostname: str = ""
    additional_hosts: List[AdditionalHost] = []
    tunnel_name: str = ""
    catch_all_service: str = ""
    nginx_proxy_manager: bool = False

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

    @field_validator("external_hostname")
    @classmethod
    def validate_external_hostname(cls, v: str) -> str:
        return v.strip()

    @field_validator("catch_all_service")
    @classmethod
    def validate_catch_all_service(cls, v: str) -> str:
        return v.strip()


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
