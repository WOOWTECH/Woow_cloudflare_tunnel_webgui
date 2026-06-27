"""Pure functions that turn route config into a cloudflared ingress config dict."""
import json
from pathlib import Path
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


def write_config_json(config: dict, path: "Path | str") -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2))
