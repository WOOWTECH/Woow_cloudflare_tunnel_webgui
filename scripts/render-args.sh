# shellcheck shell=bash
# scripts/render-args.sh: install-time values that are computed, not typed (decision D2).
# Sourced by scripts/install.sh, scripts/upgrade.sh and tests/dryrun.sh (after
# scripts/lib/quadlet-lib.sh), so CI renders exactly what a host gets.
#
#   render_args <envfile>  validate the loaded env (ql_env_load it first) and set
#                          RENDER_ARGS=(CF_IMAGE=<ref>)
#   cf_image_ref           print localhost/woow-cf-tunnel:<VERSION>-<git-sha12>[-dirty]
#
# WOOW_CF_IMAGE overrides the computed image (install.sh / upgrade.sh --image), for
# example to roll back to an earlier local build. It must be a localhost/woow-cf-tunnel tag.

CF_REPO=${CF_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
CF_IMAGE_NAME=localhost/woow-cf-tunnel

# cf_version: the pinned release from VERSION (x.y.z)
cf_version() {
  local v
  v=$(tr -d '[:space:]' <"$CF_REPO/VERSION" 2>/dev/null) || ql_die "cannot read $CF_REPO/VERSION"
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ql_die "VERSION must be x.y.z, got '$v'"
  printf '%s' "$v"
}

# cf_image_ref: the tag a build of this checkout gets. A tree with uncommitted changes
# gets a -dirty suffix (install.sh refuses it without --allow-dirty); a copy without
# git metadata gets -nogit. Both are rebuilt on every run.
cf_image_ref() {
  local ver sha
  ver=$(cf_version) || return 1
  if sha=$(git -C "$CF_REPO" rev-parse --short=12 HEAD 2>/dev/null); then
    if [[ -n $(git -C "$CF_REPO" status --porcelain 2>/dev/null) ]]; then sha+=-dirty; fi
  else
    sha=nogit
  fi
  printf '%s:%s-%s' "$CF_IMAGE_NAME" "$ver" "$sha"
}

# _cf_port <label> <value>: 1024..65535 (rootless podman cannot bind lower ports)
_cf_port() {
  ql_assert_match "$1" "$2" '[0-9]{4,5}'
  ((10#$2 >= 1024 && 10#$2 <= 65535)) || ql_die "$1: port $2 is outside 1024-65535"
}

# cf_validate_env: every value that reaches a unit or the nginx config (dies on the first bad one)
cf_validate_env() {
  local gui metrics vol listen ht
  gui=$(ql_env_get UVICORN_PORT) || ql_die "UVICORN_PORT is missing from the env file"
  metrics=$(ql_env_get CF_METRICS_ADDR) || ql_die "CF_METRICS_ADDR is missing from the env file"
  vol=$(ql_env_get CF_DATA_VOLUME) || ql_die "CF_DATA_VOLUME is missing from the env file"
  listen=$(ql_env_get AUTH_LISTEN 127.0.0.1:8888)
  ht=$(ql_env_get AUTH_HTPASSWD '%h/.config/woow-cf-tunnel/htpasswd')
  _cf_port UVICORN_PORT "$gui"
  # host networking: a non-loopback metrics port would publish /config (the ingress map)
  ql_assert_match CF_METRICS_ADDR "$metrics" '127\.0\.0\.1:[0-9]{4,5}'
  _cf_port CF_METRICS_ADDR "${metrics##*:}"
  ql_assert_match CF_DATA_VOLUME "$vol" '[A-Za-z0-9][A-Za-z0-9_.-]*'
  ql_assert_match AUTH_LISTEN "$listen" '(127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]{4,5}'
  _cf_port AUTH_LISTEN "${listen##*:}"
  ql_assert_match AUTH_HTPASSWD "$ht" '(%h|/)[A-Za-z0-9._/@+-]*'
  [[ $gui != "${metrics##*:}" ]] || ql_die "UVICORN_PORT and CF_METRICS_ADDR use the same port $gui"
  [[ $gui != "${listen##*:}" && ${metrics##*:} != "${listen##*:}" ]] \
    || ql_die "AUTH_LISTEN port ${listen##*:} collides with UVICORN_PORT or CF_METRICS_ADDR"
}

# render_args <envfile>: validate, then set RENDER_ARGS for ql_render
render_args() {
  local img
  cf_validate_env
  img=${WOOW_CF_IMAGE:-}
  if [[ -z $img ]]; then img=$(cf_image_ref) || ql_die "cannot compute the image tag"; fi
  ql_assert_match "image" "$img" "${CF_IMAGE_NAME//./\\.}:[A-Za-z0-9][A-Za-z0-9._-]*"
  [[ $img != *:latest ]] || ql_die "image $img: pin a version, not :latest"
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller (install.sh, tests/dryrun.sh)
  RENDER_ARGS=("CF_IMAGE=$img")
}
