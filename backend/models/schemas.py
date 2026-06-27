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

    mode: TunnelMode = TunnelMode.local
    tunnel_name: str = ""
    routes: List[Route] = []
    catch_all_service: str = ""
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    run_parameters: str = ""
    no_tls_verify: bool = True
    tunnel_token_masked: str = Field(default="", description="Masked token value")


class TunnelConfigWrite(BaseModel):
    """Request model for PUT /api/config."""

    tunnel_token: Optional[str] = Field(
        None, description="Raw token. If null/empty, existing token is kept."
    )
    mode: TunnelMode = TunnelMode.local
    tunnel_name: str = ""
    routes: List[Route] = []
    catch_all_service: str = ""
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    run_parameters: str = ""
    no_tls_verify: bool = True

    @field_validator("catch_all_service")
    @classmethod
    def validate_catch_all_service(cls, v: str) -> str:
        return v.strip()


class SetupState(BaseModel):
    has_cert: bool
    has_tunnel: bool
    tunnel_uuid: Optional[str] = None
    mode: TunnelMode = TunnelMode.local


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
    process_running: bool = False
