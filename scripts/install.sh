#!/usr/bin/env bash
# scripts/install.sh: install woow-cf-tunnel as rootless Quadlet units (podman 4.9.3,
# systemd --user, linger). Idempotent: an unchanged re-run changes nothing.
#
#   scripts/install.sh [--with-auth | --without-auth] [--image REF] [--allow-dirty]
#                      [--stage [--stage-dir DIR]] [--no-start] [--dry-run]
#
#   --with-auth     also install the optional Basic-auth proxy. Needs a valid htpasswd
#                   (scripts/auth-passwd.sh USER). Once installed it stays selected.
#   --without-auth  remove the auth proxy
#   --image REF     use an existing local build (localhost/woow-cf-tunnel:<tag>) instead
#                   of building this checkout
#   --allow-dirty   build a checkout with uncommitted changes (tag suffix -dirty)
#   --stage         build, render and dry-run into ~/.local/state/woow-cf-tunnel/staged
#                   (or --stage-dir) for migrate-legacy.sh / upgrade.sh; no systemd changes
#   --no-start      install the files and daemon-reload only
#   --dry-run       render, validate and report; build and change nothing
#
# The image is built locally (decision D3): localhost/woow-cf-tunnel:<VERSION>-<git-sha12>,
# Pull=never. The build runs before any unit is touched.
#
# It never restarts a running woow-cf-tunnel.service (QL_HOLD_UNITS), and refuses to
# rewrite its files while it runs: a restart drops the tunnel, which may carry your SSH
# session. scripts/upgrade.sh applies such changes, detached, with automatic rollback.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"

# ---- per-repo settings -----------------------------------------------------------------
APP=woow-cf-tunnel
ENV_FILE=$HOME/.config/$APP/$APP.env
PODMAN_MIN=4.9
TUNNEL_UNIT=woow-cf-tunnel.service
TUNNEL_CONTAINER=woow-cf-tunnel
AUTH_UNIT=woow-cf-tunnel-auth.service
AUTH_CONTAINER=woow-cf-tunnel-auth
LEGACY_UNITS=(cf-tunnel-webgui.service podman-cf-tunnel-webgui.service)
LEGACY_CONTAINERS=(cf-tunnel-webgui)
STAGE_DIR=$HOME/.local/state/woow-cf-tunnel/staged
NGINX_GID=${NGINX_GID:-101}   # gid of "nginx" in nginx:*-alpine; the htpasswd gets this group
# ------------------------------------------------------------------------------------------

with_auth=0 without_auth=0 image='' allow_dirty=0 stage=0 no_start=0
while (($#)); do
  case $1 in
    --with-auth) with_auth=1 ;;
    --without-auth) without_auth=1 ;;
    --image) image=${2:?--image needs a value}; shift ;;
    --allow-dirty) allow_dirty=1 ;;
    --stage) stage=1 ;;
    --stage-dir) STAGE_DIR=${2:?--stage-dir needs a value}; stage=1; shift ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
((!(with_auth && without_auth))) || ql_die "--with-auth and --without-auth exclude each other"
export QL_APP=$APP QL_HOLD_UNITS=$TUNNEL_UNIT
dry=0
[[ ${QL_DRY_RUN:-0} == 1 ]] && dry=1
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}

port_busy() { [[ -n $(ss -ltnH "( sport = :$1 )" 2>/dev/null) ]]; }
unit_up() {
  local s
  s=$(systemctl --user is-active "$1" 2>/dev/null || true)
  [[ $s == active || $s == activating || $s == reloading ]]
}

# ---- 1. host preflight ---------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
# upgrade.sh and migrate-legacy.sh hold the app lock while they run --stage
[[ ${CF_LOCK_HELD:-0} == 1 ]] || ql_lock "$APP"

# ---- 2. per-host settings (D2: rendered from the env file, never committed) ---------------
ql_env_ensure "$REPO/config/$APP.env.example" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 ]]; then
  ql_info "review $ENV_FILE (CF_DATA_VOLUME must name the volume to adopt), then run $0 again"
  exit 0
fi
if ((dry)) && [[ ! -f $ENV_FILE ]]; then
  ql_info "[dry-run] using the example settings"
  ENV_FILE=$REPO/config/$APP.env.example
  export QL_ENV_MODE_CHECK=0
fi
ql_env_load "$ENV_FILE"
[[ -z $image ]] || export WOOW_CF_IMAGE=$image
RENDER_ARGS=()
render_args "$ENV_FILE"
IMAGE=${RENDER_ARGS[0]#CF_IMAGE=}
GUI_PORT=$(ql_env_get UVICORN_PORT)
METRICS=$(ql_env_get CF_METRICS_ADDR)
VOLUME=$(ql_env_get CF_DATA_VOLUME)
AUTH_LISTEN=$(ql_env_get AUTH_LISTEN 127.0.0.1:8888)
HTPASSWD=$(ql_expand_home "$(ql_env_get AUTH_HTPASSWD '%h/.config/woow-cf-tunnel/htpasswd')")

# The auth proxy stays selected once installed; --with-auth / --without-auth change that.
auth=0
[[ -f $QDIR/woow-cf-tunnel-auth.container ]] && auth=1
((with_auth)) && auth=1
((without_auth)) && auth=0

tunnel_up=0
unit_up "$TUNNEL_UNIT" && tunnel_up=1

# ---- 3. legacy and conflict guards ---------------------------------------------------------
if ((!stage)); then
  for u in "${LEGACY_UNITS[@]}"; do
    if systemctl --user is-active --quiet "$u" 2>/dev/null; then
      ql_die "legacy unit $u is running; move it with scripts/migrate-legacy.sh (it keeps the tunnel up and rolls back on failure)"
    fi
  done
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if podman container exists "$c" 2>/dev/null; then
      ql_die "legacy container $c exists; use scripts/migrate-legacy.sh, or remove it once it is no longer needed"
    fi
  done
  if ((!tunnel_up)); then
    for p in "$GUI_PORT" "${METRICS##*:}"; do
      if port_busy "$p"; then ql_die "port $p is already in use (another cloudflared or GUI?); free it or change $ENV_FILE"; fi
    done
  fi
fi
if ((tunnel_up)) && [[ $IMAGE == *-dirty || $IMAGE == *-nogit ]]; then
  ql_die "$TUNNEL_UNIT is running; rebuilding $IMAGE in place would apply at its next restart, unsupervised. Commit your changes and use scripts/upgrade.sh"
fi
ql_check_container_collision "$TUNNEL_CONTAINER" "$TUNNEL_UNIT"
((auth)) && ql_check_container_collision "$AUTH_CONTAINER" "$AUTH_UNIT"

# ---- 4. image: built locally before any unit changes (D3) ----------------------------------
build_image() {
  local img=$1 rebuild=0
  case $img in *-dirty | *-nogit) rebuild=1 ;; esac
  if [[ -n ${WOOW_CF_IMAGE:-} ]]; then
    podman image exists "$img" || ql_die "--image $img does not exist locally (podman images localhost/woow-cf-tunnel)"
    return 0
  fi
  if [[ $img == *-dirty ]] && ((!allow_dirty)); then
    ql_die "the checkout has uncommitted changes; commit them, or pass --allow-dirty for a dev build"
  fi
  if ((!rebuild)) && podman image exists "$img"; then
    ql_info "image $img is already built"
    return 0
  fi
  if ((dry)); then ql_info "[dry-run] would build $img"; return 0; fi
  ql_info "building $img from $REPO (the running service is not touched; a few minutes)"
  podman build --pull=missing \
    --label "org.opencontainers.image.revision=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --label "org.opencontainers.image.version=$(cf_version)" \
    -t "$img" "$REPO" >&2 || ql_die "podman build failed; nothing was changed"
}
build_image "$IMAGE"
if ((!dry)) || podman image exists "$IMAGE" 2>/dev/null; then
  # shellcheck disable=SC2016 # expanded by the inner sh
  podman unshare sh -c 'm=$(podman image mount "$1") && test -x "$m/usr/local/bin/cf-webui-healthcheck"; r=$?; podman image unmount "$1" >/dev/null; exit $r' _ "$IMAGE" \
    || ql_die "$IMAGE lacks /usr/local/bin/cf-webui-healthcheck; HealthOnFailure=kill would restart it in a loop"
fi

# ---- 5. optional auth proxy: validate before rendering -------------------------------------
check_htpasswd() {
  local bad
  [[ -s $HTPASSWD ]] || ql_die "--with-auth: $HTPASSWD is missing or empty (create it: scripts/auth-passwd.sh USER)"
  # shellcheck disable=SC2016 # literal $ in the crypt-format regex
  bad=$(grep -vnE '^[A-Za-z0-9._@-]+:\$(2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}|6\$[^$:]+\$[./A-Za-z0-9]{86}|5\$[^$:]+\$[./A-Za-z0-9]{43}|apr1\$[./A-Za-z0-9]{1,8}\$[./A-Za-z0-9]{22})$' "$HTPASSWD" | cut -d: -f1 | tr '\n' ' ' || true)
  [[ -z $bad ]] || ql_die "--with-auth: $HTPASSWD has malformed line(s) $bad(want user:bcrypt | sha512-crypt | sha256-crypt | apr1)"
  if ! unit_up "$AUTH_UNIT" && port_busy "${AUTH_LISTEN##*:}"; then
    # --stage: a migration may take over the port the legacy GUI listens on
    if ((stage)); then ql_warn "--with-auth: port ${AUTH_LISTEN##*:} is in use now; it must be free when the auth proxy starts"
    else ql_die "--with-auth: port ${AUTH_LISTEN##*:} is already in use (set AUTH_LISTEN in $ENV_FILE)"; fi
  fi
  if ((dry)); then ql_info "[dry-run] would set $HTPASSWD to mode 0640, group = nginx subgid"; return 0; fi
  chmod 640 "$HTPASSWD"
  podman unshare chgrp "$NGINX_GID" "$HTPASSWD" || ql_die "cannot give $HTPASSWD the nginx group (podman unshare chgrp $NGINX_GID)"
}
((auth)) && check_htpasswd

# ---- 6. render the selected units, validate with the 4.9.3 generator ------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$WORK/src/"
((auth)) && cp -p "$REPO/quadlet/optional/woow-cf-tunnel-auth.container" "$WORK/src/"
VARS=$REPO/quadlet/render-vars
ql_render "$WORK/src" "$ENV_FILE" "$VARS" "$WORK/out" "${RENDER_ARGS[@]}"
((auth)) && ql_render "$REPO/config/auth/auth-nginx.conf" "$ENV_FILE" "$VARS" "$WORK/out/config"
refs=()
[[ -d $QDIR ]] && refs=(--ref-dir "$QDIR")
ql_dryrun "$WORK/out" --verify "${refs[@]}" || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

if ((stage)); then
  if ((dry)); then ql_info "[dry-run] would stage into $STAGE_DIR"; exit 0; fi
  rm -rf -- "$STAGE_DIR"
  mkdir -p -- "$STAGE_DIR"
  chmod 700 "$STAGE_DIR"
  cp -a -- "$WORK/out/." "$STAGE_DIR/"
  ql_info "staged in $STAGE_DIR: image $IMAGE, volume $VOLUME, GUI 127.0.0.1:$GUI_PORT, metrics $METRICS$( ((auth)) && echo ", auth proxy $AUTH_LISTEN")"
  exit 0
fi

# ---- 7. never rewrite a running tunnel's units --------------------------------------------
if ((tunnel_up)); then
  for f in woow-cf-tunnel.container woow-cf-tunnel-data.volume; do
    if ! cmp -s "$WORK/out/$f" "$QDIR/$f"; then
      ql_die "$TUNNEL_UNIT is running and $f would change (new image or settings). Apply it with scripts/upgrade.sh; nothing was changed"
    fi
  done
fi

# ---- 8. images, then files; start or restart only what changed ------------------------------
if ((dry)); then
  ql_info "[dry-run] would pull: $(grep -h '^Image=' "$WORK/out"/*.container | grep -v "$IMAGE" | tr '\n' ' ')"
else
  ql_pull_images "$WORK/out"
fi
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if ((without_auth)) && [[ -f $QDIR/woow-cf-tunnel-auth.container ]]; then
  ql_remove_files "$APP" woow-cf-tunnel-auth.container config/auth-nginx.conf
fi
if grep -qx 'config/auth-nginx.conf' <<<"$changed"; then ql_mark_changed "$APP" "$AUTH_UNIT"; fi
if ((dry)); then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
units=("$TUNNEL_UNIT")
((auth)) && units+=("$AUTH_UNIT")
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start ${units[*]}"
  exit 0
fi
auth_was_up=0
unit_up "$AUTH_UNIT" && auth_was_up=1
ql_apply_units "$APP" "${units[@]}"

# ---- 9. smoke -------------------------------------------------------------------------------
if ((!tunnel_up)) || { ((auth)) && [[ -n $changed || $auth_was_up == 0 ]]; }; then
  "$REPO/tests/smoke.sh" || ql_die "smoke checks failed; see: journalctl --user -u $TUNNEL_UNIT -n 100"
fi
ql_info "installed. Open the GUI through an SSH port-forward: ssh -L $GUI_PORT:127.0.0.1:$GUI_PORT <this host>, then http://localhost:$GUI_PORT"
