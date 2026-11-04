from pathlib import Path

from backend import __version__


def test_backend_version_matches_the_version_file():
    assert (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip() == __version__
