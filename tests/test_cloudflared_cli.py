from backend.services.cloudflared_cli import extract_login_url


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
