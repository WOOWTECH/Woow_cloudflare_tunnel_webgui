#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move a legacy cf-tunnel-webgui deployment (a hand-written user
# unit running `podman run ... -v cf_data:/data`, as on toypark1234) to the woow-cf-tunnel
# Quadlet units, adopting the data volume in place.
#
# THE TUNNEL MAY CARRY YOUR SSH SESSION. Run this over another path (for example the
# tailnet). The swap runs as a detached `systemd-run --user` watchdog, so it finishes, or
# rolls back, even if your session drops.
#
#   scripts/migrate-legacy.sh preflight [--allow-dirty] [--with-auth] [--image REF]
#       1. install.sh --stage: build the image while the legacy unit keeps serving, render
#       2. read-only checks (access path, rescue path, legacy health, staged units)
#       3. podman volume export of the data volume, legacy unit/config/inspect/image copies,
#          and - where the legacy container would be revived at boot - its rollback capture
#       4. baseline: every public hostname's HTTP code, the config version, the connection
#          count and the hostname map. Prints RUN (~/.local/state/woow-cf-tunnel/migrate-*)
#   scripts/migrate-legacy.sh swap [RUN]        start the detached watchdog; returns at once
#   scripts/migrate-legacy.sh status [RUN]      phase, result and the last log lines
#   scripts/migrate-legacy.sh commit [RUN]      end the soak early and keep the new units
#   scripts/migrate-legacy.sh abort [RUN]       ask the running watchdog to roll back now
#   scripts/migrate-legacy.sh --rollback [RUN]  manual rollback when no watchdog runs
# RUN defaults to the newest run. Every command also accepts the --command form.
#
# Rollback shape (STANDARD 7a): the swap does not rename the legacy container - the Quadlet
# container has another name - it only stops it and disables its unit. That keeps a rollback
# only while nothing starts it again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled AND the
# legacy container's restart policy is exactly `always`, the next reboot brings a second
# cloudflared up on the same tunnel token, the same /data volume and the same host ports.
# podman 4.9.3 cannot change a restart policy afterwards, so preflight then captures the
# container (before any downtime) and the swap removes it; every rollback path recreates it
# with ql_recreate_container before it starts the legacy unit. ql_rollback_strategy asks this
# host's real state, never its name, and preflight prints which shape applies.
#
# Watchdog: re-check the legacy tunnel -> install the staged units -> stop and disable the
# legacy unit (its file is kept, and the container itself either stays stopped or is removed
# after its capture) -> start woow-cf-tunnel.service -> within GATE_TIMEOUT
# (180s): unit active, GUI /api/health 200, EXPECT_CONNS (4) edge connections, config
# version and hostname map unchanged, podman health "healthy", every public hostname
# returns its baseline code -> soak SOAK_SECONDS (600s): no restart, no inactive unit,
# connections kept. Any failure, timeout, signal or crash before "committed" rolls back to
# the legacy unit automatically.
#
# Settings (env): LEGACY_UNIT LEGACY_CONTAINER LEGACY_GUI_PORT RESCUE_CONTAINER (none to skip)
#   EXTRA_UNITS HTTP_OVERRIDES ("host=code ...") EXPECT_CONNS GATE_TIMEOUT SOAK_SECONDS
#   POLL SOAK_POLL LEGACY_READY_TIMEOUT SAVE_LEGACY_IMAGE (1)
# The tunnel token is never read or printed.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$HERE/lib/quadlet-lib.sh"
# shellcheck source=lib/cf-gate.sh
. "$HERE/lib/cf-gate.sh"
export QL_LOG_PREFIX=migrate-legacy QL_APP=$CF_APP

LEGACY_UNIT=${LEGACY_UNIT:-cf-tunnel-webgui.service}
LEGACY_CONTAINER=${LEGACY_CONTAINER:-cf-tunnel-webgui}
LEGACY_GUI_PORT=${LEGACY_GUI_PORT:-}
RESCUE_CONTAINER=${RESCUE_CONTAINER:-woow-tailscale}
LEGACY_READY_TIMEOUT=${LEGACY_READY_TIMEOUT:-120}
SAVE_LEGACY_IMAGE=${SAVE_LEGACY_IMAGE:-1}
QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
ENV_FILE=$HOME/.config/$CF_APP/$CF_APP.env
PREFIX=migrate

usage() { sed -n '2,46p' "$0"; exit 64; }
run_arg() {
  local r=${1:-}
  [[ -n $r ]] || r=$(cf_latest_run "$PREFIX")
  [[ -n $r && -d $r ]] || ql_die "no migrate run found; run: $0 preflight"
  printf '%s' "$(cd "$r" && pwd -P)"
}

# ---- preflight ------------------------------------------------------------------------------
cmd_preflight() {
  local allow_tunnel=0 problems=0
  local -a stage_args=()
  while (($#)); do
    case $1 in
      --allow-dirty | --with-auth) stage_args+=("$1") ;;
      --image) stage_args+=(--image "${2:?--image needs a value}"); shift ;;
      --allow-tunnel-session) allow_tunnel=1 ;;
      *) ql_die "preflight: unknown option $1" ;;
    esac
    shift
  done
  ok() { echo "  ok    $1"; }
  bad() { echo "  FAIL  $1"; problems=$((problems + 1)); }
  check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
  same_nonempty() { [[ -n $1 && $1 == "$2" ]]; }
  none_installed() { [[ ! -e $QUADLET_DIR/woow-cf-tunnel.container && ! -e $QUADLET_DIR/woow-cf-tunnel-data.volume ]]; }

  echo "== access path"
  echo "  ssh client address: ${SSH_CONNECTION:-<no SSH_CONNECTION>}"
  if cf_session_rides_tunnel; then
    echo "  path: $CF_SESSION_PATH -- $CF_SESSION_WHY"
    if ((allow_tunnel)); then echo "  WARN  this session is treated as riding the tunnel (override given)"
    else bad "the swap drops this session: $CF_SESSION_WHY. Reconnect over the tailnet, or pass --allow-tunnel-session"; fi
  else
    ok "this session does not ride the tunnel ($CF_SESSION_WHY)"
  fi
  if [[ $RESCUE_CONTAINER != none ]]; then
    check "rescue path: container $RESCUE_CONTAINER running" \
      test "$(podman inspect -f '{{.State.Status}}' "$RESCUE_CONTAINER" 2>/dev/null)" = running
  fi
  ((problems == 0)) || { echo "preflight: $problems problem(s); nothing was changed."; return 1; }

  ql_lock "$CF_APP"
  STAGE_DIR=$CF_STATE_ROOT/staged
  echo "== 1. build and stage (the legacy unit keeps serving)"
  if [[ ! -f $ENV_FILE ]]; then
    CF_LOCK_HELD=1 "$HERE/install.sh" --stage --stage-dir "$STAGE_DIR" "${stage_args[@]}" || true
    ql_die "created $ENV_FILE: check CF_DATA_VOLUME (the legacy volume), UVICORN_PORT and CF_METRICS_ADDR, then re-run preflight"
  fi
  CF_LOCK_HELD=1 "$HERE/install.sh" --stage --stage-dir "$STAGE_DIR" "${stage_args[@]}" \
    || { echo "preflight: staging failed; nothing was changed."; return 1; }
  local cont=$STAGE_DIR/woow-cf-tunnel.container vol=$STAGE_DIR/woow-cf-tunnel-data.volume
  GUI_PORT=$(sed -n 's/^Environment=UVICORN_PORT=//p' "$cont")
  METRICS_ADDR=$(sed -n 's/^Environment=CF_METRICS_ADDR=//p' "$cont")
  LEGACY_GUI_PORT=${LEGACY_GUI_PORT:-$GUI_PORT}
  local staged_img staged_vol legacy_vol legacy_img n
  staged_img=$(sed -n 's/^Image=//p' "$cont")
  staged_vol=$(sed -n 's/^VolumeName=//p' "$vol")
  if [[ -f $STAGE_DIR/woow-cf-tunnel-auth.container && " $EXTRA_UNITS " != *" woow-cf-tunnel-auth.service "* ]]; then
    EXTRA_UNITS="${EXTRA_UNITS:+$EXTRA_UNITS }woow-cf-tunnel-auth.service"
  fi

  echo "== 2. checks"
  check "$LEGACY_UNIT active" systemctl --user is-active --quiet "$LEGACY_UNIT"
  check "$LEGACY_UNIT enabled" test "$(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null)" = enabled
  check "$LEGACY_UNIT file kept for rollback: ~/.config/systemd/user/$LEGACY_UNIT" test -f "$HOME/.config/systemd/user/$LEGACY_UNIT"
  legacy_vol=$(podman inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$LEGACY_CONTAINER" 2>/dev/null)
  echo "  legacy /data volume: ${legacy_vol:-<none>}; staged VolumeName=$staged_vol"
  check "legacy /data is a named volume" test -n "$legacy_vol"
  check "staged VolumeName equals the legacy volume (CF_DATA_VOLUME in $ENV_FILE)" same_nonempty "$staged_vol" "$legacy_vol"
  n=$(cf_ready_conns)
  check "legacy cloudflared readyConnections=$n (want $EXPECT_CONNS) on $METRICS_ADDR" test "$n" -ge "$EXPECT_CONNS"
  check "legacy GUI answers on 127.0.0.1:$LEGACY_GUI_PORT" cf_gui_ok "$LEGACY_GUI_PORT"
  check "staged image $staged_img present" podman image exists "$staged_img"
  check "$NEW_UNIT not installed yet" test "$(systemctl --user show -p LoadState --value "$NEW_UNIT" 2>/dev/null)" = not-found
  check "no woow-cf-tunnel Quadlet file installed yet" none_installed
  check "systemd-run available" command -v systemd-run
  check "linger enabled" test "$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null)" = yes
  # How the legacy container is kept for a rollback. The swap never renames it - the new
  # Quadlet container has another name - so on a host where podman-restart.service would
  # revive it at boot it has to be captured and removed instead (STANDARD 7a).
  LEGACY_STRATEGY=$(ql_rollback_strategy "$LEGACY_CONTAINER")
  echo "  rollback shape: $LEGACY_STRATEGY ($LEGACY_CONTAINER restart-policy=$(ql_container_restart_policy "$LEGACY_CONTAINER"), podman-restart.service $(systemctl --user is-enabled podman-restart.service 2>/dev/null || echo disabled))"
  ((problems == 0)) || { echo "preflight: $problems problem(s); nothing was changed."; return 1; }

  local run stamp bdir tarball
  run=$(cf_new_run "$PREFIX") || ql_die "cannot create a run dir under $CF_STATE_ROOT"
  stamp=${run##*/"$PREFIX"-}
  bdir=$CF_BACKUP_ROOT/woow-cf-tunnel-$PREFIX-$stamp
  echo "== 3. backup -> $bdir (the volume export CONTAINS THE TUNNEL TOKEN: keep it 0600, on this host)"
  tarball=$(ql_backup_volume "$legacy_vol" "$bdir") || { echo "  FAIL  volume export"; return 1; }
  (
    umask 077
    tar -tf "$tarball" >"$bdir/$legacy_vol.list" &&
      cp -p "$HOME/.config/systemd/user/$LEGACY_UNIT" "$bdir/" &&
      { [[ ! -d $HOME/.config/cf-tunnel-webgui ]] || cp -a "$HOME/.config/cf-tunnel-webgui" "$bdir/config-cf-tunnel-webgui"; } &&
      podman inspect "$LEGACY_CONTAINER" >"$bdir/legacy-container.inspect.json" &&
      systemctl --user cat "$LEGACY_UNIT" >"$bdir/legacy-unit.cat"
  ) || { echo "  FAIL  backup of the legacy unit and container"; return 1; }
  if [[ $LEGACY_STRATEGY == capture ]]; then
    cf_legacy_capture "$bdir" "$LEGACY_CONTAINER" \
      || { echo "  FAIL  capturing $LEGACY_CONTAINER for the rollback"; return 1; }
    echo "  rollback copy: $bdir/legacy-container/$LEGACY_CONTAINER (the swap removes the live container; --rollback recreates it)"
  fi
  legacy_img=$(podman inspect -f '{{.ImageName}}' "$LEGACY_CONTAINER" 2>/dev/null)
  if [[ $SAVE_LEGACY_IMAGE == 1 && -n $legacy_img ]]; then
    (umask 077 && podman save -o "$bdir/legacy-image.tar" "$legacy_img") || { echo "  FAIL  podman save $legacy_img"; return 1; }
  fi
  echo "  $(du -sh "$bdir" | cut -f1) in $bdir; volume entries: $(grep -c . "$bdir/$legacy_vol.list")"

  echo "== 4. baseline"
  RUN=$run
  cf_baseline "$run" 1 || { echo "preflight: the baseline is not usable; nothing was changed."; return 1; }

  # shellcheck disable=SC2034 # recorded in run.env for the watchdog
  BACKUP_DIR=$bdir LEGACY_VOLUME=$legacy_vol LEGACY_IMAGE=$legacy_img STAGED_IMAGE=$staged_img
  cf_write_run_env "$run" LEGACY_UNIT LEGACY_CONTAINER LEGACY_GUI_PORT LEGACY_READY_TIMEOUT QUADLET_DIR \
    STAGE_DIR BACKUP_DIR LEGACY_VOLUME LEGACY_IMAGE STAGED_IMAGE LEGACY_STRATEGY \
    BASELINE_TUNNEL BASELINE_VERSION BASELINE_INGRESS_SHA
  cp -a "$STAGE_DIR" "$run/staged"
  cf_freeze "$run" "$HERE/migrate-legacy.sh"
  echo "preflight OK. RUN=$run"
  echo "next: $0 swap $run"
}

# ---- watchdog -------------------------------------------------------------------------------
staged_names() { # installed names of the staged set: top-level units and config/<path>
  (cd "$STAGE_DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
}

rollback() {
  local reason=$1 u f n=0 deadline
  case ${PHASE:-} in rolling_back | rolled_back | rollback_failed) return 0 ;; esac
  trap '' TERM INT HUP # finish the rollback even if asked to stop again
  cf_phase rolling_back
  cf_log "ROLLBACK: $reason"
  for u in $EXTRA_UNITS; do timeout 60 systemctl --user stop "$u" 2>/dev/null; done
  timeout 90 systemctl --user stop "$NEW_UNIT" 2>/dev/null
  podman rm -f -i "$NEW_CONTAINER" >/dev/null 2>&1
  mkdir -p "$RUN/rolled-back-units"
  while IFS= read -r f; do
    case $f in
      config/*) [[ -f $HOME/.config/$CF_APP/${f#config/} ]] && cp -p "$HOME/.config/$CF_APP/${f#config/}" "$RUN/rolled-back-units/" ;;
      *) [[ -f $QUADLET_DIR/$f ]] && cp -p "$QUADLET_DIR/$f" "$RUN/rolled-back-units/" ;;
    esac
  done < <(staged_names)
  cf_run ql_uninstall_units "$CF_APP" || cf_log "ql_uninstall_units failed; removing the files directly"
  while IFS= read -r f; do [[ $f == config/* ]] || rm -f "$QUADLET_DIR/$f"; done < <(staged_names)
  systemctl --user daemon-reload
  systemctl --user reset-failed "$NEW_UNIT" 2>/dev/null
  cf_legacy_restore "${BACKUP_DIR:-}" "$LEGACY_CONTAINER" || true
  systemctl --user enable "$LEGACY_UNIT"
  systemctl --user start "$LEGACY_UNIT"
  deadline=$(($(date +%s) + LEGACY_READY_TIMEOUT))
  while (($(date +%s) < deadline)); do
    n=$(cf_ready_conns)
    ((n >= 1)) && cf_gui_ok "$LEGACY_GUI_PORT" && break
    sleep "$POLL"
  done
  if ((n >= 1)); then
    cf_phase rolled_back
    cf_result "ROLLED_BACK ($reason); $LEGACY_UNIT active and enabled, readyConnections=$n"
    exit 2
  fi
  cf_phase rollback_failed
  cf_result "ROLLBACK_FAILED ($reason): the legacy tunnel is not ready after ${LEGACY_READY_TIMEOUT}s. Use the tailnet; backup in $BACKUP_DIR"
  exit 3
}

on_exit() {
  local rc=$1
  case ${PHASE:-pre} in
    pre) [[ -s $RUN/RESULT ]] || cf_result "ABORTED_BEFORE_CHANGE (watchdog exited rc=$rc before any change)" ;;
    committed | rolled_back | rollback_failed | rolling_back) ;;
    *) rollback "watchdog exited unexpectedly (rc=$rc) during phase $PHASE" ;;
  esac
}

cmd_watchdog() {
  RUN=${1:?}
  # shellcheck source=/dev/null
  . "$RUN/run.env"
  CF_LOG=$RUN/watchdog.log
  STAGE_DIR=$RUN/staged
  trap '' PIPE
  cf_phase pre
  trap 'on_exit $?' EXIT
  trap 'cf_log "signal received"; exit 143' TERM INT HUP
  unset QL_HOLD_UNITS # this watchdog is the one place that starts the new tunnel unit
  ql_lock "$CF_APP"

  local n waited=0 frag
  n=$(cf_ready_conns)
  if ! systemctl --user is-active --quiet "$LEGACY_UNIT" || ((n < EXPECT_CONNS)); then
    cf_result "ABORTED_BEFORE_CHANGE: the legacy tunnel is not healthy at swap time (readyConnections=$n)"
    exit 1
  fi

  cf_phase installing
  cf_run ql_install_files "$STAGE_DIR" "$CF_APP" || rollback "installing the staged units failed"
  systemctl --user daemon-reload
  [[ $(systemctl --user show -p LoadState --value "$NEW_UNIT") == loaded ]] || rollback "the Quadlet generator did not produce $NEW_UNIT"
  frag=$(systemctl --user show -p FragmentPath --value "$NEW_UNIT")
  [[ $frag == */systemd/generator/* ]] || rollback "$NEW_UNIT is loaded from $frag, which shadows the generated unit"

  cf_phase stopping_legacy
  T_DOWN=$(date +%s)
  timeout 90 systemctl --user stop "$LEGACY_UNIT" || rollback "stopping $LEGACY_UNIT failed"
  systemctl --user disable "$LEGACY_UNIT" || rollback "disabling $LEGACY_UNIT failed"
  while [[ $(podman inspect -f '{{.State.Running}}' "$LEGACY_CONTAINER" 2>/dev/null) == true ]] ||
    cf_port_busy "$LEGACY_GUI_PORT" || cf_port_busy "$GUI_PORT" || cf_port_busy "${METRICS_ADDR##*:}"; do
    ((waited < 30)) || rollback "the legacy container still runs, or port $LEGACY_GUI_PORT/$GUI_PORT/${METRICS_ADDR##*:} is busy, 30s after the stop"
    sleep 1
    waited=$((waited + 1))
  done

  # The legacy container is stopped and its unit disabled. On a host where
  # podman-restart.service would start it again at boot (policy `always`), leaving it there
  # would put a second cloudflared on this tunnel and these host ports after the next reboot,
  # so it goes away now and the rollback recreates it from the capture taken in preflight.
  if [[ ${LEGACY_STRATEGY:-rename} == capture ]]; then
    cf_legacy_remove "$BACKUP_DIR" "$LEGACY_CONTAINER" || rollback "removing the legacy container failed"
  fi

  cf_phase starting_new
  # shellcheck disable=SC2086 # EXTRA_UNITS is a word list
  cf_run ql_apply_units "$CF_APP" "$NEW_UNIT" $EXTRA_UNITS || rollback "starting $NEW_UNIT failed"

  cf_gate_and_soak rollback
  cf_phase committed
  cf_result "SUCCESS: $NEW_UNIT serves the tunnel (config v$BASELINE_VERSION); $LEGACY_UNIT disabled, file kept; backup in $BACKUP_DIR"
  exit 0
}

cmd_swap() {
  local run unit age
  run=$(run_arg "${1:-}")
  [[ -s $run/run.env ]] || ql_die "$run has no run.env; run preflight first"
  age=$(($(date +%s) - $(stat -c %Y "$run/run.env")))
  ((age < 1800)) || ql_die "the baseline is $((age / 60)) min old; run preflight again"
  [[ ! -e $run/PHASE ]] || ql_die "$run was already used (phase $(cat "$run/PHASE")); run preflight again"
  if cf_session_rides_tunnel; then ql_warn "this session is treated as riding the tunnel and will drop during the swap ($CF_SESSION_WHY); the watchdog carries on"; fi
  unit=woow-cf-tunnel-migrate-${run##*/"$PREFIX"-}
  cf_detach "$run" "$unit" migrate-legacy.sh "woow-cf-tunnel legacy -> Quadlet swap watchdog" \
    || ql_die "systemd-run failed; nothing was changed"
  echo "watchdog started as $unit (gate ${GATE_TIMEOUT}s, soak ${SOAK_SECONDS}s). Follow it with:"
  echo "  journalctl --user -fu $unit      or      $0 status $run"
}

cmd_manual_rollback() {
  RUN=$(run_arg "${1:-}")
  # shellcheck source=/dev/null
  . "$RUN/run.env"
  CF_LOG=$RUN/watchdog.log
  STAGE_DIR=$RUN/staged
  if systemctl --user is-active --quiet "woow-cf-tunnel-migrate-${RUN##*/"$PREFIX"-}"; then
    ql_die "the watchdog of $RUN is still running; ask it to roll back with: $0 abort $RUN"
  fi
  ql_lock "$CF_APP"
  PHASE=manual
  rollback "manual rollback requested"
}

case ${1:-} in
  preflight | --preflight) shift; cmd_preflight "$@" ;;
  swap | --swap) shift; cmd_swap "$@" ;;
  status | --status) shift; cf_status "$(run_arg "${1:-}")" ;;
  commit | --commit) shift; r=$(run_arg "${1:-}"); touch "$r/COMMIT"; echo "commit requested ($r)" ;;
  abort | --abort) shift; r=$(run_arg "${1:-}"); touch "$r/ROLLBACK"; echo "rollback requested ($r)" ;;
  rollback | --rollback) shift; cmd_manual_rollback "$@" ;;
  __watchdog) shift; cmd_watchdog "$@" ;;
  *) usage ;;
esac
