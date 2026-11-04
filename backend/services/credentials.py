"""Keep the credential files on /data private, without reading them.

Same rules as the HA add-on's cloudflared-credential-guard (1.1.1): a backup
restore or a hand copy can leave cert.pem or tunnel.json world-readable. At
startup, and after the GUI creates one, each existing file is re-owned to the
runtime user and set to 0600. A symlink, a hardlink or a non-regular file is
refused, because chmod through it would change some other file. Missing files
are fine (a fresh install has none).
"""
import os
import stat
from pathlib import Path

NAMES = ("cert.pem", "tunnel.json", ".tunnel_token", "paas-link.json", ".csrf_secret")


class CredentialError(Exception):
    """A credential file could not be made private. The message never names
    the file's contents."""


def protect(directory: "Path | str" = "/data", names: tuple[str, ...] = NAMES) -> None:
    try:
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise CredentialError("credential directory is not accessible") from exc
    try:
        for name in names:
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory_fd)
            except FileNotFoundError:
                continue
            except OSError as exc:
                # ELOOP: the name is a symlink.
                raise CredentialError(f"{name} is not a regular file") from exc
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                    raise CredentialError(f"{name} is not a single-link regular file")
                if (before.st_uid, before.st_gid) != (os.geteuid(), os.getegid()):
                    os.fchown(fd, os.geteuid(), os.getegid())
                os.fchmod(fd, 0o600)
                after = os.fstat(fd)
                current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if ((current.st_dev, current.st_ino) != (after.st_dev, after.st_ino)
                        or after.st_nlink != 1
                        or stat.S_IMODE(after.st_mode) != 0o600):
                    raise CredentialError(f"{name} changed while it was being protected")
            except OSError as exc:
                raise CredentialError(f"{name} could not be made private") from exc
            finally:
                os.close(fd)
    finally:
        os.close(directory_fd)
