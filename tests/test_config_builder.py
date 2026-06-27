from backend.services.config_builder import build_ingress_config


def test_empty_routes_produces_only_catch_all_404():
    cfg = build_ingress_config(
        tunnel_uuid="uuid-123",
        credentials_file="/data/tunnel.json",
        routes=[],
    )
    assert cfg["tunnel"] == "uuid-123"
    assert cfg["credentials-file"] == "/data/tunnel.json"
    assert cfg["ingress"] == [
        {"service": "http_status:404", "originRequest": {"noTLSVerify": True}}
    ]
