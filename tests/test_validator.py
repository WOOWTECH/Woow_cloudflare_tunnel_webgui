"""
測試 4: Validator 安全性測試
涵蓋: 容器映像白名單、Token 格式驗證、注入攻擊防護
"""

import pytest

from backend.services.validator import validate_image, validate_tunnel_token


# =========================================================================
# Image 白名單驗證
# =========================================================================
class TestValidateImage:
    """只允許 cloudflare/cloudflared 官方映像。"""

    @pytest.mark.parametrize(
        "image",
        [
            "cloudflare/cloudflared:latest",
            "docker.io/cloudflare/cloudflared:latest",
            "cloudflare/cloudflared:2024.1.0",
            "cloudflare/cloudflared:2024.12.1",
            "docker.io/cloudflare/cloudflared:2024.1.0-rc1",
        ],
    )
    def test_valid_images(self, image):
        assert validate_image(image) is True

    @pytest.mark.parametrize(
        "image,reason",
        [
            ("nginx:latest", "非 cloudflared 映像"),
            ("cloudflare/cloudflared", "缺少 tag"),
            ("evil/cloudflared:latest", "偽造 namespace"),
            ("cloudflare/cloudflared:latest; rm -rf /", "注入攻擊"),
            ("docker.io/evil/cloudflared:latest", "偽造 namespace with registry"),
            ("ghcr.io/cloudflare/cloudflared:latest", "非 docker.io registry"),
            ("", "空字串"),
            ("cloudflare/cloudflared:", "空 tag"),
        ],
    )
    def test_invalid_images(self, image, reason):
        assert validate_image(image) is False, f"應拒絕: {reason}"


# =========================================================================
# Tunnel Token 驗證
# =========================================================================
class TestValidateTunnelToken:
    """Token 長度 >= 10，禁止 shell 特殊字元。"""

    def test_valid_jwt_token(self):
        # 模擬典型的 eyJ... base64 JWT token
        token = "eyJhIjoiMTIzIiwidCI6IjQ1NiIsInMiOiI3ODkifQ=="
        assert validate_tunnel_token(token) is True

    def test_valid_api_token(self):
        token = "VbABwopRd9lHzUvwCsuFos6eb4bhUKXmcCadtYpr"
        assert validate_tunnel_token(token) is True

    def test_token_too_short(self):
        assert validate_tunnel_token("abc") is False
        assert validate_tunnel_token("123456789") is False  # 9 chars

    def test_token_exactly_10_chars(self):
        assert validate_tunnel_token("1234567890") is True

    def test_empty_token(self):
        assert validate_tunnel_token("") is False

    def test_none_like_empty(self):
        # None 不是 str，但 validate_tunnel_token 先判斷 falsy
        assert validate_tunnel_token("") is False

    @pytest.mark.parametrize(
        "bad_token",
        [
            "token;inject",
            "token&inject",
            "token|inject",
            "token`inject`",
            "token$(inject)",
            "token(){inject}",
        ],
    )
    def test_shell_injection_rejected(self, bad_token):
        assert validate_tunnel_token(bad_token) is False
