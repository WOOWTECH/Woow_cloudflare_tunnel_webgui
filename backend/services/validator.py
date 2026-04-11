import re

ALLOWED_IMAGE_PATTERN = re.compile(
    r"^(docker\.io/)?cloudflare/cloudflared:(latest|[\d]+\.[\d]+\.[\d]+.*)$"
)


def validate_image(image: str) -> bool:
    """Only allow cloudflare/cloudflared images."""
    return bool(ALLOWED_IMAGE_PATTERN.match(image))


def validate_tunnel_token(token: str) -> bool:
    """Tunnel tokens are alphanumeric strings (base64 JWT or API tokens)."""
    if not token or len(token) < 10:
        return False
    if re.search(r"[;&|`$(){}]", token):
        return False
    return True
