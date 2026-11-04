"""External observation labels based on real Cloudflare Access redirect shapes
(same cases as the HA add-on)."""

import pytest

from backend.services.external_probe import classify_response, probe


def test_cloudflare_team_login_redirect_is_recognized():
    hostname = "sa-gui-e2e-1024-122f4b.woowtech.io"
    location = ("https://woowtech.cloudflareaccess.com/cdn-cgi/access/login/"
                + hostname + "?kid=example")
    assert classify_response(302, location, hostname, "cloudflare") == "login_required"


def test_similar_looking_redirect_does_not_claim_access_protection():
    hostname = "sa-gui-e2e-1024-122f4b.woowtech.io"
    path = "/cdn-cgi/access/login/" + hostname
    assert classify_response(302, "https://woowtech.cloudflareaccess.com.evil.test" + path,
                             hostname, "cloudflare") == "undetermined"
    assert classify_response(302, "http://woowtech.cloudflareaccess.com" + path,
                             hostname, "cloudflare") == "undetermined"
    assert classify_response(302, "https://woowtech.cloudflareaccess.com" + path,
                             hostname, "nginx") == "undetermined"


def test_anonymous_200_remains_public_response():
    assert classify_response(200, "", "ha.example.com", "cloudflare") == "public_response"


@pytest.mark.asyncio
@pytest.mark.parametrize("hostname", ["127.0.0.1", "nas.local", "localhost"])
async def test_private_or_local_names_are_not_probed(hostname):
    assert (await probe(hostname))["status"] == "blocked_private_address"
