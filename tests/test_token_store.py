"""Unit tests for TokenStore (file-backed tunnel token)."""
import stat

from backend.services.token_store import TokenStore


def test_set_then_has_is_true(tmp_path):
    store = TokenStore(path=tmp_path / ".tunnel_token")
    assert store.has() is False
    store.set("my-token")
    assert store.has() is True


def test_get_returns_original_value(tmp_path):
    store = TokenStore(path=tmp_path / ".tunnel_token")
    store.set("super-secret-token")
    assert store.get() == "super-secret-token"


def test_get_masked_returns_mask_when_set(tmp_path):
    store = TokenStore(path=tmp_path / ".tunnel_token")
    store.set("super-secret-token")
    assert store.get_masked() == "********"


def test_unset_has_is_false_and_get_none(tmp_path):
    store = TokenStore(path=tmp_path / ".tunnel_token")
    assert store.has() is False
    assert store.get() is None


def test_unset_masked_is_empty_string(tmp_path):
    store = TokenStore(path=tmp_path / ".tunnel_token")
    assert store.get_masked() == ""


def test_set_writes_file_with_0600_permissions(tmp_path):
    path = tmp_path / ".tunnel_token"
    store = TokenStore(path=path)
    store.set("my-token")
    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode == 0o600
