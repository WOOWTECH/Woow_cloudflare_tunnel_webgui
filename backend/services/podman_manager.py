import logging
import os
from datetime import datetime, timezone
from typing import Optional, Iterator

from podman import PodmanClient
from podman.errors import NotFound, APIError

logger = logging.getLogger(__name__)

PODMAN_SOCKET = os.getenv(
    "PODMAN_SOCKET_PATH", "unix:///run/podman/podman.sock"
)


class PodmanManager:
    def __init__(self, socket_url: str = PODMAN_SOCKET):
        self._socket_url = socket_url

    def _client(self) -> PodmanClient:
        return PodmanClient(base_url=self._socket_url)

    # ── Secret Operations ──────────────────────────────

    def secret_exists(self, name: str) -> bool:
        with self._client() as client:
            try:
                client.secrets.get(name)
                return True
            except NotFound:
                return False
            except APIError:
                return False

    def secret_set(self, name: str, value: str) -> str:
        """Create or replace a podman secret. Returns secret ID."""
        with self._client() as client:
            # Podman secrets are immutable — remove old one first
            try:
                old = client.secrets.get(name)
                old.remove()
            except (NotFound, APIError):
                pass
            secret = client.secrets.create(name=name, data=value.encode())
            return secret.id

    def secret_get_masked(self, name: str) -> str:
        """Return masked placeholder if secret exists."""
        if self.secret_exists(name):
            return "********"
        return ""

    # ── Container Operations ───────────────────────────

    def get_status(self, container_name: str) -> dict:
        with self._client() as client:
            try:
                ctr = client.containers.get(container_name)
                info = ctr.inspect()
                state = info.get("State", {})
                started_at = state.get("StartedAt")
                uptime_seconds = None
                if state.get("Status") == "running" and started_at:
                    try:
                        # Podman timestamps: "2024-01-01T00:00:00.000000000+08:00"
                        started = datetime.fromisoformat(
                            started_at.replace("Z", "+00:00")[:32]
                        )
                        uptime_seconds = int(
                            (datetime.now(timezone.utc) - started.astimezone(timezone.utc)).total_seconds()
                        )
                    except (ValueError, TypeError):
                        pass
                return {
                    "status": state.get("Status", "unknown"),
                    "container_id": ctr.id,
                    "image": str(info.get("ImageName", info.get("Image", ""))),
                    "started_at": started_at,
                    "uptime_seconds": uptime_seconds,
                    "exit_code": state.get("ExitCode"),
                    "restart_count": state.get("RestartCount", 0),
                }
            except NotFound:
                return {"status": "not_found"}
            except APIError as e:
                logger.error("Podman API error getting status: %s", e)
                return {"status": "unknown"}

    def start_container(
        self,
        container_name: str,
        image: str,
        secret_name: str,
        post_quantum: bool,
        log_level: str,
        extra_args: str,
    ) -> str:
        """Create and start the cloudflared container. Returns container ID."""
        with self._client() as client:
            # Remove existing container if any
            try:
                old = client.containers.get(container_name)
                old.remove(force=True)
            except (NotFound, APIError):
                pass

            # Build command
            cmd = ["tunnel", "run"]
            if post_quantum:
                cmd.append("--post-quantum")
            if log_level and log_level != "info":
                cmd.extend(["--loglevel", log_level])
            if extra_args:
                cmd.extend(extra_args.split())

            # Create with secret injected as TUNNEL_TOKEN env var
            # Use host network so cloudflared can reach services on the host
            ctr = client.containers.create(
                image=image,
                name=container_name,
                command=cmd,
                secret_env={"TUNNEL_TOKEN": secret_name},
                detach=True,
                restart_policy={"Name": "unless-stopped"},
                network_mode="host",
            )
            ctr.start()
            return ctr.id

    def stop_container(self, container_name: str, timeout: int = 30) -> bool:
        with self._client() as client:
            try:
                ctr = client.containers.get(container_name)
                try:
                    ctr.stop(timeout=timeout)
                except Exception as e:
                    # podman-py may raise JSONDecodeError on empty 204 response
                    if "JSONDecodeError" in type(e).__name__ or "Expecting value" in str(e):
                        pass  # stop succeeded, response was empty
                    else:
                        raise
                return True
            except NotFound:
                return False

    def restart_container(self, container_name: str, timeout: int = 30) -> bool:
        with self._client() as client:
            try:
                ctr = client.containers.get(container_name)
                try:
                    ctr.restart(timeout=timeout)
                except Exception as e:
                    if "JSONDecodeError" in type(e).__name__ or "Expecting value" in str(e):
                        pass
                    else:
                        raise
                return True
            except NotFound:
                return False

    def stream_logs(self, container_name: str, tail: int = 200) -> Iterator[bytes]:
        """Return a blocking streaming iterator of container logs."""
        with self._client() as client:
            try:
                ctr = client.containers.get(container_name)
                return ctr.logs(
                    stdout=True,
                    stderr=True,
                    stream=True,
                    follow=True,
                    tail=tail,
                    timestamps=True,
                )
            except NotFound:
                return iter([])

    def ping(self) -> bool:
        try:
            with self._client() as client:
                client.ping()
                return True
        except Exception:
            return False
