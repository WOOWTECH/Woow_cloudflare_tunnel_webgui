# shellcheck shell=bash
# tests/harness/common.sh: shared setup for the harness (sourced by run-all.sh and
# scenario.sh). Every case runs the real scripts against mocked podman, systemctl, curl,
# ss, loginctl and systemd-run (tests/harness/bin), under a throwaway HOME. The Quadlet
# generator and systemd-analyze are real; no container is ever created.

HARNESS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC_REPO=$(cd "$HARNESS/../.." && pwd -P)
: "${HARNESS_TMP:?HARNESS_TMP must be set}"
ORIG_PATH=${ORIG_PATH:-$PATH}
export ORIG_PATH
R=$HARNESS_TMP/repo

# snapshot_repo: a clean git copy of the working tree (tracked + untracked, not ignored),
# so image tags are <VERSION>-<sha> whatever state the dev checkout is in.
snapshot_repo() {
  [[ -d $R/.git ]] && return 0
  mkdir -p "$R"
  (cd "$SRC_REPO" && git ls-files -z -co --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e $f ]] && printf '%s\0' "$f"; done |
    tar --null -T - -cf -) | tar -xf - -C "$R"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" -c user.name=harness -c user.email=harness@localhost commit -qm snapshot
}

# new_commit: move the snapshot to a new commit (an upgrade produces a new image tag)
new_commit() {
  echo "$1" >>"$R/.harness-bump"
  git -C "$R" add .harness-bump
  git -C "$R" -c user.name=harness -c user.email=harness@localhost commit -qm "$1"
}

image_ref() { printf 'localhost/woow-cf-tunnel:%s-%s' "$(tr -d '[:space:]' <"$R/VERSION")" "$(git -C "$R" rev-parse --short=12 HEAD)"; }

# sandbox <name>: fresh HOME and mock state; the mocks first on PATH; a tailnet SSH session
sandbox() {
  local d=$HARNESS_TMP/case-$1
  rm -rf "$d"
  mkdir -p "$d/state" "$d/home/.config/systemd/user" "$d/run" "$d/proc"
  export MOCK_STATE=$d/state HOME=$d/home XDG_RUNTIME_DIR=$d/run SMOKE_PROC=$d/proc
  export PATH=$HARNESS/bin:$ORIG_PATH USER=toypark1234
  export SSH_CONNECTION="100.113.239.105 50000 100.112.215.78 22"
  unset QL_DRY_RUN WOOW_CF_IMAGE MOCK_SCENARIO MOCK_BAD_IMAGE MOCK_PERSIST MOCK_LEGACY_VOL \
    MOCK_EXTRA_ING MOCK_BUSY_PORTS MOCK_FAIL_START MOCK_NO_METRICS MOCK_SSH_CARRIER \
    LEGACY_UNIT LEGACY_GUI_PORT GUI_PORT EXTRA_UNITS HTTP_OVERRIDES RESCUE_CONTAINER \
    EXPECT_CONNS
  export MOCK_WARMUP=0
  : >"$MOCK_STATE/calls.log"
}

# legacy_host: the toypark1234 deployment (hand-written unit running podman run --rm ... -v cf_data:/data)
legacy_host() {
  echo 1 >"$MOCK_STATE/legacy_active"
  echo 1 >"$MOCK_STATE/legacy_enabled"
  touch "$MOCK_STATE/legacy_container"
  printf '[Unit]\nDescription=legacy cf-tunnel-webgui\n[Service]\nExecStart=/usr/bin/podman run --rm --name cf-tunnel-webgui -v cf_data:/data localhost/cf-webui:8214177d40f4\n[Install]\nWantedBy=default.target\n' \
    >"$HOME/.config/systemd/user/cf-tunnel-webgui.service"
  mkdir -p "$HOME/.config/cf-tunnel-webgui"
  printf '#!/bin/sh\n' >"$HOME/.config/cf-tunnel-webgui/healthcheck.sh"
}

env_file() {
  mkdir -p "$HOME/.config/woow-cf-tunnel"
  chmod 700 "$HOME/.config/woow-cf-tunnel"
  install -m 600 "$R/config/woow-cf-tunnel.env.example" "$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env"
}
set_env() { sed -i "s|^$1=.*|$1=$2|" "$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env"; }
calls() { grep -cE -- "$1" "$MOCK_STATE/calls.log" 2>/dev/null || true; }
QDIR() { printf '%s' "$HOME/.config/containers/systemd"; }

# assertions: a case function runs them, then returns $A_FAILS
A_FAILS=0
t() { "$@" || { echo "  assert failed: $*"; A_FAILS=$((A_FAILS + 1)); }; }
tnot() { if "$@"; then echo "  assert should have failed: $*"; A_FAILS=$((A_FAILS + 1)); fi; }
has_line() { grep -qx -- "$1" "$2"; }
