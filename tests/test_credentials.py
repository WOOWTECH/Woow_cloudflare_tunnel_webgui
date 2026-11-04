"""
測試: /data 憑證檔權限防護(對齊 HA add-on 1.1.1 的 cloudflared-credential-guard)
涵蓋: 0644 修成 0600、symlink 與 hardlink 拒絕且不動到目標、缺檔可接受、不讀檔案內容
"""

import os

import pytest

from backend.services import credentials


def test_world_readable_credentials_become_private(tmp_path):
    for name in ("cert.pem", "tunnel.json", ".tunnel_token"):
        (tmp_path / name).write_text("secret")
        os.chmod(tmp_path / name, 0o644)
    credentials.protect(tmp_path)
    for name in ("cert.pem", "tunnel.json", ".tunnel_token"):
        assert (tmp_path / name).stat().st_mode & 0o777 == 0o600
        assert (tmp_path / name).read_text() == "secret"


def test_missing_files_and_missing_directory_are_fine(tmp_path):
    credentials.protect(tmp_path)
    credentials.protect(tmp_path / "absent")


def test_symlink_is_refused_and_its_target_untouched(tmp_path):
    target = tmp_path / "elsewhere"
    target.write_text("x")
    os.chmod(target, 0o644)
    (tmp_path / "tunnel.json").symlink_to(target)
    with pytest.raises(credentials.CredentialError):
        credentials.protect(tmp_path)
    assert target.stat().st_mode & 0o777 == 0o644


def test_hardlink_is_refused_and_both_names_untouched(tmp_path):
    other = tmp_path / "other"
    other.write_text("x")
    os.chmod(other, 0o644)
    os.link(other, tmp_path / "cert.pem")
    with pytest.raises(credentials.CredentialError):
        credentials.protect(tmp_path)
    assert other.stat().st_mode & 0o777 == 0o644


def test_error_message_never_contains_file_contents(tmp_path):
    target = tmp_path / "elsewhere"
    target.write_text("PRIVATE-CONTENT")
    (tmp_path / "cert.pem").symlink_to(target)
    with pytest.raises(credentials.CredentialError) as info:
        credentials.protect(tmp_path)
    assert "PRIVATE-CONTENT" not in str(info.value)
