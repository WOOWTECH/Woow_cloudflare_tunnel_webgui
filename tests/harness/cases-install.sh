# shellcheck shell=bash
# tests/harness/cases-install.sh: scripts/install.sh and scripts/auth-passwd.sh cases
# (sourced by run-all.sh). Each case_* function returns the number of failed assertions.

STAGED() { printf '%s' "$HOME/.local/state/woow-cf-tunnel/staged"; }
valid_htpasswd() {
  mkdir -p "$HOME/.config/woow-cf-tunnel"
  echo 'correct-horse-battery' | bash "$R/scripts/auth-passwd.sh" admin >/dev/null
}

case_install_first_run_creates_env_and_stops() {
  sandbox first-run
  t "$R/scripts/install.sh"
  t test "$(stat -c %a "$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env")" = 600
  tnot test -e "$(QDIR)/woow-cf-tunnel.container"
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_install_stage_while_legacy_runs() {
  sandbox stage
  legacy_host
  env_file
  t "$R/scripts/install.sh" --stage
  local s img
  s=$(STAGED) img=$(image_ref)
  t has_line "Image=$img" "$s/woow-cf-tunnel.container"
  t has_line 'Pull=never' "$s/woow-cf-tunnel.container"
  t has_line 'Environment=UVICORN_PORT=18000' "$s/woow-cf-tunnel.container"
  t has_line 'Environment=CF_METRICS_ADDR=127.0.0.1:20241' "$s/woow-cf-tunnel.container"
  t has_line 'VolumeName=cf_data' "$s/woow-cf-tunnel-data.volume"
  tnot test -e "$s/woow-cf-tunnel-auth.container"
  t test "$(calls "podman build .* -t $img")" = 1
  t test "$(calls 'systemctl --user (start|restart|stop|enable|disable|daemon-reload)')" = 0
  tnot test -e "$(QDIR)/woow-cf-tunnel.container"
  t test "$(cat "$MOCK_STATE/legacy_active")" = 1
  # a second --stage reuses the built image
  t "$R/scripts/install.sh" --stage
  t test "$(calls 'podman build')" = 1
  return "$A_FAILS"
}

case_install_refuses_while_legacy_runs() {
  sandbox refuse-legacy
  legacy_host
  env_file
  local out
  out=$("$R/scripts/install.sh" 2>&1) && { echo "  install succeeded while legacy runs"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'migrate-legacy.sh' <<<"$out"
  tnot test -e "$(QDIR)/woow-cf-tunnel.container"
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_install_fresh_then_idempotent() {
  sandbox fresh
  env_file
  t "$R/scripts/install.sh"
  t test -f "$(QDIR)/woow-cf-tunnel.container"
  t test -f "$(QDIR)/woow-cf-tunnel-data.volume"
  t test "$(cat "$MOCK_STATE/units/woow-cf-tunnel.service/active")" = 1
  t test "$(cat "$MOCK_STATE/running_image")" = "$(image_ref)"
  t grep -q woow-cf-tunnel.container "$HOME/.local/state/woow-quadlet/woow-cf-tunnel/manifest"
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/install.sh"
  t test "$(calls 'systemctl --user (start|restart|stop)')" = 0
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_install_never_rewrites_a_running_tunnel() {
  sandbox running-change
  env_file
  t "$R/scripts/install.sh"
  local before out
  before=$(sha256sum "$(QDIR)/woow-cf-tunnel.container")
  set_env UVICORN_PORT 18001
  : >"$MOCK_STATE/calls.log"
  out=$("$R/scripts/install.sh" 2>&1) && { echo "  install rewrote a running tunnel"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'upgrade.sh' <<<"$out"
  t test "$(sha256sum "$(QDIR)/woow-cf-tunnel.container")" = "$before"
  t test "$(calls 'systemctl --user (restart|stop)')" = 0
  # a new commit (new image tag) is refused the same way
  set_env UVICORN_PORT 18000
  new_commit install-running
  out=$("$R/scripts/install.sh" 2>&1) && { echo "  install applied a new image to a running tunnel"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'upgrade.sh' <<<"$out"
  t test "$(sha256sum "$(QDIR)/woow-cf-tunnel.container")" = "$before"
  return "$A_FAILS"
}

case_install_refuses_bad_settings() {
  sandbox bad-settings
  env_file
  set_env CF_METRICS_ADDR 0.0.0.0:20241
  tnot "$R/scripts/install.sh"
  set_env CF_METRICS_ADDR 127.0.0.1:20241
  tnot "$R/scripts/install.sh" --image localhost/woow-cf-tunnel:latest
  tnot "$R/scripts/install.sh" --image localhost/woow-cf-tunnel:0.0.0-missing
  export MOCK_BUSY_PORTS=18000
  tnot "$R/scripts/install.sh"
  unset MOCK_BUSY_PORTS
  tnot test -e "$(QDIR)/woow-cf-tunnel.container"
  return "$A_FAILS"
}

case_install_stage_adopts_compose_volume() {
  sandbox compose-volume
  env_file
  set_env CF_DATA_VOLUME woow_cloudflare_tunnel_webgui_cf_data
  t "$R/scripts/install.sh" --stage
  t has_line 'VolumeName=woow_cloudflare_tunnel_webgui_cf_data' "$(STAGED)/woow-cf-tunnel-data.volume"
  return "$A_FAILS"
}

case_install_auth_refuses_malformed_htpasswd() {
  sandbox auth-bad
  env_file
  t "$R/scripts/install.sh"
  printf 'admin:plaintext-password\n' >"$HOME/.config/woow-cf-tunnel/htpasswd"
  : >"$MOCK_STATE/calls.log"
  tnot "$R/scripts/install.sh" --with-auth
  tnot test -e "$(QDIR)/woow-cf-tunnel-auth.container"
  tnot test -e "$HOME/.config/woow-cf-tunnel/auth-nginx.conf"
  rm -f "$HOME/.config/woow-cf-tunnel/htpasswd"
  tnot "$R/scripts/install.sh" --with-auth
  return "$A_FAILS"
}

case_install_auth_adds_proxy_without_touching_the_tunnel() {
  sandbox auth-ok
  env_file
  t "$R/scripts/install.sh"
  valid_htpasswd
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/install.sh" --with-auth
  local conf=$HOME/.config/woow-cf-tunnel/auth-nginx.conf
  t test -f "$(QDIR)/woow-cf-tunnel-auth.container"
  t has_line '        listen 127.0.0.1:8888;' "$conf"
  t has_line '            proxy_pass http://127.0.0.1:18000;' "$conf"
  t test "$(stat -c %a "$HOME/.config/woow-cf-tunnel/htpasswd")" = 640
  t grep -q "chgrp 101 $HOME/.config/woow-cf-tunnel/htpasswd" "$MOCK_STATE/chgrp.log"
  t test "$(cat "$MOCK_STATE/units/woow-cf-tunnel-auth.service/active")" = 1
  t test "$(calls 'systemctl --user (restart|stop) .*woow-cf-tunnel.service')" = 0
  t test "$(calls 'podman pull docker.io/library/nginx:1.30.4-alpine')" = 1
  # stays selected on a plain re-run; --without-auth removes it
  t "$R/scripts/install.sh"
  t test -f "$(QDIR)/woow-cf-tunnel-auth.container"
  t "$R/scripts/install.sh" --without-auth
  tnot test -e "$(QDIR)/woow-cf-tunnel-auth.container"
  tnot test -e "$conf"
  t test "$(cat "$MOCK_STATE/units/woow-cf-tunnel.service/active")" = 1
  return "$A_FAILS"
}

case_install_dry_run_changes_nothing() {
  sandbox dry-run
  t "$R/scripts/install.sh" --dry-run
  tnot test -e "$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env"
  tnot test -e "$(QDIR)"
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

# shellcheck disable=SC2034 # read by run-all.sh
INSTALL_CASES=(
  case_install_first_run_creates_env_and_stops
  case_install_stage_while_legacy_runs
  case_install_refuses_while_legacy_runs
  case_install_fresh_then_idempotent
  case_install_never_rewrites_a_running_tunnel
  case_install_refuses_bad_settings
  case_install_stage_adopts_compose_volume
  case_install_auth_refuses_malformed_htpasswd
  case_install_auth_adds_proxy_without_touching_the_tunnel
  case_install_dry_run_changes_nothing
)
