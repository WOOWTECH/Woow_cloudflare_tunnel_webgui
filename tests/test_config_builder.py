import json

from backend.services.config_builder import build_ingress_config, write_config_json


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


def test_disable_chunked_true_written_to_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[
        {"hostname": "h", "service": "s", "disableChunkedEncoding": True}])
    assert cfg["ingress"][0]["originRequest"]["disableChunkedEncoding"] is True


def test_disable_chunked_false_written_to_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[
        {"hostname": "h", "service": "s", "disableChunkedEncoding": False}])
    assert cfg["ingress"][0]["originRequest"]["disableChunkedEncoding"] is False


def test_disable_chunked_absent_not_in_origin_request():
    cfg = build_ingress_config("u", "/c", routes=[{"hostname": "h", "service": "s"}])
    assert "disableChunkedEncoding" not in cfg["ingress"][0]["originRequest"]


def test_catch_all_service_replaces_404():
    cfg = build_ingress_config("u", "/c", routes=[],
                               catch_all_service="http://192.168.1.100")
    assert cfg["ingress"][-1] == {
        "service": "http://192.168.1.100",
        "originRequest": {"noTLSVerify": True},
    }


def test_no_tls_verify_false_omits_origin_request_key():
    cfg = build_ingress_config("u", "/c",
        routes=[{"hostname": "h", "service": "s"}], no_tls_verify=False)
    assert "originRequest" not in cfg["ingress"][0]   # 無任何 origin 設定 → 不產生空 dict
    assert "originRequest" not in cfg["ingress"][-1]   # catch-all 同理


def test_multiple_routes_preserve_order_with_catch_all_last():
    routes = [
        {"hostname": "a", "service": "s1"},
        {"hostname": "b", "service": "s2"},
        {"hostname": "c", "service": "s3"},
    ]
    cfg = build_ingress_config("u", "/c", routes=routes)
    hosts = [e.get("hostname") for e in cfg["ingress"]]
    assert hosts == ["a", "b", "c", None]   # None = catch-all
    assert cfg["ingress"][-1]["service"] == "http_status:404"


def test_write_config_json_roundtrip(tmp_path):
    cfg = build_ingress_config("u", "/c", routes=[{"hostname": "h", "service": "s"}])
    out = tmp_path / "config.json"
    write_config_json(cfg, out)
    assert json.loads(out.read_text()) == cfg
