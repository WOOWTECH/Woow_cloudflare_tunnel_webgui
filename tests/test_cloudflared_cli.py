import asyncio
import json

import pytest

from backend.services.cloudflared_cli import CloudflaredCLI, extract_login_url


def test_extract_login_url_finds_argotunnel_url():
    text = (
        "Please open the following URL and log in with your Cloudflare account:\n\n"
        "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin\n\n"
        "Leave cloudflared running to download the cert automatically.\n"
    )
    url = extract_login_url(text)
    assert url == "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin"


def test_extract_login_url_returns_none_when_absent():
    assert extract_login_url("no url here") is None


@pytest.mark.asyncio
async def test_run_returns_stdout_and_zero_rc():
    cli = CloudflaredCLI(binary="/bin/echo")
    rc, out, err = await cli._run(["hello"])
    assert rc == 0
    assert out.strip() == "hello"


@pytest.mark.asyncio
async def test_run_nonzero_rc_on_false():
    cli = CloudflaredCLI(binary="/usr/bin/false")
    rc, out, err = await cli._run([])
    assert rc != 0


@pytest.mark.asyncio
async def test_create_tunnel_returns_uuid(tmp_path, monkeypatch):
    cred = tmp_path / "tunnel.json"

    async def fake_run(args):
        cred.write_text(json.dumps({"TunnelID": "uuid-xyz", "AccountTag": "a"}))
        return 0, "Created tunnel demo with id uuid-xyz", ""

    cli = CloudflaredCLI(binary="cloudflared")
    monkeypatch.setattr(cli, "_run", fake_run)
    uuid = await cli.create_tunnel(name="demo", cred_file=str(cred))
    assert uuid == "uuid-xyz"


@pytest.mark.asyncio
async def test_create_tunnel_raises_on_failure(tmp_path, monkeypatch):
    async def fake_run(args):
        return 1, "", "tunnel name already exists"

    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    with pytest.raises(RuntimeError, match="already exists"):
        await cli.create_tunnel(name="demo", cred_file=str(tmp_path / "t.json"))


@pytest.mark.asyncio
async def test_route_dns_passes_force_uuid_hostname(monkeypatch):
    captured = {}

    async def fake_run(args):
        captured["args"] = args
        return 0, "", ""

    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    await cli.route_dns(tunnel_uuid="u1", hostname="a.example.com")
    a = captured["args"]
    assert "route" in a and "dns" in a and "-f" in a
    assert a[-2:] == ["u1", "a.example.com"]


@pytest.mark.asyncio
async def test_route_dns_raises_on_failure(monkeypatch):
    async def fake_run(args):
        return 1, "", "zone not found"
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    with pytest.raises(RuntimeError, match="zone not found"):
        await cli.route_dns("u1", "a.example.com")


@pytest.mark.asyncio
async def test_ingress_validate_ok(monkeypatch):
    async def fake_run(args):
        assert "validate" in args
        return 0, "OK", ""
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    ok, output = await cli.ingress_validate("/data/config.json")
    assert ok is True


@pytest.mark.asyncio
async def test_ingress_validate_fail(monkeypatch):
    async def fake_run(args):
        return 1, "", "validation error: duplicated hostname"
    cli = CloudflaredCLI()
    monkeypatch.setattr(cli, "_run", fake_run)
    ok, output = await cli.ingress_validate("/data/config.json")
    assert ok is False
    assert "duplicated" in output


class _FakeProc:
    def __init__(self, lines, cert_path):
        self._lines = lines
        self._cert = cert_path
        self.returncode = None

    async def _drain(self):
        await asyncio.sleep(0)

    @property
    def stdout(self):
        async def gen():
            for ln in self._lines:
                yield ln.encode()
            # 模擬使用者完成授權後 cloudflared 寫出 cert 並結束
            from pathlib import Path
            Path(self._cert).write_text("FAKE CERT")
        return _AsyncLineReader(gen())

    async def wait(self):
        self.returncode = 0
        return 0


class _AsyncLineReader:
    def __init__(self, agen):
        self._agen = agen
    def __aiter__(self):
        return self._agen


@pytest.mark.asyncio
async def test_login_yields_url_then_writes_cert(tmp_path, monkeypatch):
    cert = tmp_path / "cert.pem"
    src_cert = tmp_path / "src_cert.pem"
    lines = [
        "Please open the following URL:\n",
        "https://dash.cloudflare.com/argotunnel?aud=x\n",
    ]

    async def fake_exec(*args, **kwargs):
        return _FakeProc(lines, src_cert)

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    cli = CloudflaredCLI()
    urls = []
    async for url in cli.login(src_cert=str(src_cert), dest_cert=str(cert)):
        urls.append(url)
    assert urls == ["https://dash.cloudflare.com/argotunnel?aud=x"]
    assert cert.read_text() == "FAKE CERT"   # 已搬到 dest
