#!/usr/bin/env bash
# scripts/auth-passwd.sh USER: add USER to, or change USER's password in, the htpasswd
# of the optional auth proxy (AUTH_HTPASSWD in ~/.config/woow-cf-tunnel/woow-cf-tunnel.env,
# default ~/.config/woow-cf-tunnel/htpasswd).
#
# The password is read from the terminal (asked twice), or from stdin when piped. It is
# never taken from argv. The hash is SHA-512-crypt ($6$) from `openssl passwd -6 -stdin`:
# openssl ships with Ubuntu, and nginx:alpine (musl crypt) verifies $6$. The file gets
# mode 0640 and the nginx subgid as its group, so nginx workers can read it.
# nginx reads the file on every request: no restart is needed.
set -euo pipefail
user=${1:?usage: auth-passwd.sh USER}
[[ $user =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "auth-passwd: invalid user name (use A-Z a-z 0-9 . _ @ -)" >&2; exit 64; }
env_file=${ENV_FILE:-$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env}
ht=''
[[ -r $env_file ]] && ht=$(sed -n 's/^AUTH_HTPASSWD=//p' "$env_file" | tail -n1)
ht=${ht:-%h/.config/woow-cf-tunnel/htpasswd}
ht=${ht//%h/$HOME}
dir=$(dirname -- "$ht")
mkdir -p -- "$dir"
if [[ -t 0 ]]; then
  read -rsp "password for $user: " pw
  echo
  read -rsp "again: " pw2
  echo
  [[ $pw == "$pw2" ]] || { echo "auth-passwd: the passwords differ" >&2; exit 1; }
else
  IFS= read -r pw || true
fi
((${#pw} >= 12)) || { echo "auth-passwd: use at least 12 characters" >&2; exit 1; }
hash=$(printf '%s\n' "$pw" | openssl passwd -6 -stdin)
unset pw pw2
tmp=$(mktemp "$dir/.htpasswd.XXXXXX")
trap 'rm -f "$tmp"' EXIT
{
  if [[ -f $ht ]]; then grep -v "^${user}:" "$ht" || true; fi
  printf '%s:%s\n' "$user" "$hash"
} >"$tmp"
chmod 640 "$tmp"
mv -f -- "$tmp" "$ht"
trap - EXIT
podman unshare chgrp "${NGINX_GID:-101}" "$ht"
echo "auth-passwd: updated $ht (user $user). First time? Run: scripts/install.sh --with-auth"
