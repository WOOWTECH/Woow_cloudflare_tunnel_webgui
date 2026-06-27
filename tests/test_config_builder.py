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


def test_single_route_has_hostname_service_and_no_tls_verify():
    cfg = build_ingress_config(
        "uuid", "/data/tunnel.json",
        routes=[{"hostname": "a.example.com", "service": "http://localhost:8080"}],
    )
    assert cfg["ingress"][0] == {
        "hostname": "a.example.com",
        "service": "http://localhost:8080",
        "originRequest": {"noTLSVerify": True},
    }
    # catch-all 仍在最後
    assert cfg["ingress"][-1]["service"] == "http_status:404"
