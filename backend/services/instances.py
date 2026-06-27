"""Shared singleton service instances.

All routers import these so they operate on the SAME ProcessManager /
ConfigManager / TokenStore / CloudflaredCLI. Creating per-router instances
(the previous behaviour) siloed state — e.g. the tunnel router started
cloudflared on its own ProcessManager while the health/logs routers observed
a different, empty one.
"""
from .config_manager import ConfigManager
from .process_manager import ProcessManager
from .token_store import TokenStore
from .cloudflared_cli import CloudflaredCLI

pm = ProcessManager()
config_mgr = ConfigManager()
token_store = TokenStore()
cli = CloudflaredCLI()
