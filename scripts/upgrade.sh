#!/usr/bin/env bash
# scripts/upgrade.sh: apply repo changes (a new VERSION or commit, a new cloudflared, edited
# settings) to a running woow-cf-tunnel, with a gate and an automatic rollback.
#
# RESTARTING THE TUNNEL DROPS IT FOR ~20-40s, and it may carry your SSH session. The swap
# therefore runs in a detached `systemd-run --user` watchdog: it finishes, or rolls back to
# the units that are installed now, even if your session drops.
#
#   scripts/upgrade.sh [--image REF] [--no-follow] [--gate-timeout S] [--soak S]
#       1. build the new image while the old container keeps running (install.sh --stage)
#       2. snapshot the installed units as the rollback target, back up the data volume
#       3. baseline (connections, config version, hostname map, public HTTP codes)
#       4. detached watchdog: install -> restart -> gate -> soak -> commit
#   scripts/upgrade.sh --prepare-only        steps 1-3 only; prints RUN
#   scripts/upgrade.sh swap [RUN]            start the watchdog for a prepared run
#   scripts/upgrade.sh status [RUN]          phase, result and the last log lines
#   scripts/upgrade.sh commit [RUN]          end the soak early and keep the new units
#   scripts/upgrade.sh abort [RUN]           ask the running watchdog to roll back now
#   scripts/upgrade.sh --rollback [RUN]      manual rollback to that run's previous units
#
# Upgrading = change the repo (bump VERSION, the pinned cloudflared version, the units),
# commit, then run this. A checkout with uncommitted changes is refused: its image tag
# would not identify what is running. Use --image to redeploy an earlier local build.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$HERE/lib/quadlet-lib.sh"
_env_expect=${EXPECT_CONNS:-}
# shellcheck source=lib/cf-gate.sh
. "$HERE/lib/cf-gate.sh"
export QL_LOG_PREFIX=upgrade QL_APP=$CF_APP

QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
CONF_DIR=$HOME/.config/$CF_APP
ENV_FILE=$CONF_DIR/$CF_APP.env
AUTH_UNIT=woow-cf-tunnel-auth.service
RESTORE_TIMEOUT=${RESTORE_TIMEOUT:-180}
PREFIX=upgrade
QUADLET_NAMES=(woow-cf-tunnel.container woow-cf-tunnel-data.volume woow-cf-tunnel-auth.container)
CONFIG_NAMES=(auth-nginx.conf)

usage() { sed -n '2,25p' "$0"; exit 64; }
run_arg() {
  local r=${1:-}
  [[ -n $r ]] || r=$(cf_latest_run "$PREFIX")
  [[ -n $r && -d $r ]] || ql_die "no upgrade run found; run: $0"
  printf '%s' "$(cd "$r" && pwd -P)"
}
units_of() { # units the set in <dir> installs, tunnel first
  local d=$1
  printf '%s' "$NEW_UNIT"
  [[ -f $d/woow-cf-tunnel-auth.container ]] && printf ' %s' "$AUTH_UNIT"
}

# ---- prepare --------------------------------------------------------------------------------
cmd_prepare() {
  local no_follow=0 prepare_only=0 run f n
  local -a stage_args=()
  while (($#)); do
    case $1 in
      --image) stage_args+=(--image "${2:?--image needs a value}"); shift ;;
      --with-auth | --without-auth | --allow-dirty) stage_args+=("$1") ;;
      --no-follow) no_follow=1 ;;
      --prepare-only) prepare_only=1 ;;
      --gate-timeout) GATE_TIMEOUT=${2:?--gate-timeout needs seconds}; shift ;;
      --soak) SOAK_SECONDS=${2:?--soak needs seconds}; shift ;;
      *) ql_die "unknown option $1 (see --help)" ;;
    esac
    shift
  done
  ql_preflight 4.9
  ql_lock "$CF_APP"
  [[ -f $QUADLET_DIR/woow-cf-tunnel.container ]] || ql_die "woow-cf-tunnel is not installed here; use scripts/install.sh"
  [[ -f $ENV_FILE ]] || ql_die "$ENV_FILE is missing; use scripts/install.sh"

  run=$(cf_new_run "$PREFIX") || ql_die "cannot create a run dir under $CF_STATE_ROOT"
  RUN=$run
  ql_info "1. building and rendering the new set (the running container is not touched)"
  CF_LOCK_HELD=1 "$HERE/install.sh" --stage --stage-dir "$run/new" "${stage_args[@]}" \
    || { rm -rf "$run"; ql_die "staging failed; nothing was changed"; }

  ql_info "2. snapshotting the installed units as the rollback target"
  mkdir -p "$run/previous"
  for f in "${QUADLET_NAMES[@]}"; do [[ -f $QUADLET_DIR/$f ]] && cp -p "$QUADLET_DIR/$f" "$run/previous/"; done
  for f in "${CONFIG_NAMES[@]}"; do
    if [[ -f $CONF_DIR/$f ]]; then
      mkdir -p "$run/previous/config"
      cp -p "$CONF_DIR/$f" "$run/previous/config/"
    fi
  done
  if diff -r "$run/previous" "$run/new" >/dev/null 2>&1; then
    rm -rf "$run"
    if systemctl --user is-active --quiet "$NEW_UNIT"; then
      ql_info "already up to date: the rendered units match the installed ones"
    else
      ql_info "already up to date, but $NEW_UNIT is not running; start it with scripts/install.sh"
    fi
    return 0
  fi
  ql_info "changes:"
  diff -r "$run/previous" "$run/new" | sed 's/^/    /' >&2

  UNITS=$(units_of "$run/new")
  PREV_UNITS=$(units_of "$run/previous")
  EXTRA_UNITS=''
  [[ -f $run/new/woow-cf-tunnel-auth.container ]] && EXTRA_UNITS=$AUTH_UNIT
  GUI_PORT=$(sed -n 's/^Environment=UVICORN_PORT=//p' "$run/new/woow-cf-tunnel.container")
  METRICS_ADDR=$(sed -n 's/^Environment=CF_METRICS_ADDR=//p' "$run/new/woow-cf-tunnel.container")

  ql_info "3. backing up the data volume (the export CONTAINS THE TUNNEL TOKEN)"
  CF_LOCK_HELD=1 "$HERE/backup.sh" >/dev/null || ql_die "backup failed; nothing was changed"

  ql_info "4. baseline"
  cf_baseline "$run" 0 || ql_die "the baseline is not usable; nothing was changed"
  n=$(<"$run/ready_conns")
  if [[ -z $_env_expect ]] && ((n > 0)); then EXPECT_CONNS=$n; fi

  cf_write_run_env "$run" QUADLET_DIR RESTORE_TIMEOUT UNITS PREV_UNITS \
    BASELINE_TUNNEL BASELINE_VERSION BASELINE_INGRESS_SHA
  cf_freeze "$run" "$HERE/upgrade.sh"
  echo "upgrade: RUN=$run"
  ((prepare_only)) && return 0
  cmd_swap "$run" || return 1
  ((no_follow)) && return 0
  # Release the lock before following: the watchdog takes it.
  cmd_follow "$run"
}

cmd_swap() {
  local run unit
  run=$(run_arg "${1:-}")
  [[ -s $run/run.env ]] || ql_die "$run has no run.env; run $0 --prepare-only first"
  [[ ! -e $run/PHASE ]] || ql_die "$run was already used (phase $(cat "$run/PHASE"))"
  if cf_session_rides_tunnel; then ql_warn "this session is treated as riding the tunnel and may drop during the restart ($CF_SESSION_WHY); the watchdog carries on"; fi
  unit=woow-cf-tunnel-upgrade-${run##*/"$PREFIX"-}
  cf_detach "$run" "$unit" upgrade.sh "woow-cf-tunnel upgrade watchdog" \
    || ql_die "systemd-run failed; nothing was changed"
  ql_info "watchdog started as $unit (gate ${GATE_TIMEOUT}s, soak ${SOAK_SECONDS}s); follow: journalctl --user -fu $unit"
}

cmd_follow() {
  local run=$1 seen=0 total
  while [[ ! -s $run/RESULT ]]; do
    total=$(wc -l <"$run/watchdog.log" 2>/dev/null || echo 0)
    if ((total > seen)); then
      sed -n "$((seen + 1)),\$p" "$run/watchdog.log"
      seen=$total
    fi
    sleep 2
  done
  total=$(wc -l <"$run/watchdog.log" 2>/dev/null || echo 0)
  ((total > seen)) && sed -n "$((seen + 1)),\$p" "$run/watchdog.log"
  grep -q '^SUCCESS' "$run/RESULT"
}

# ---- watchdog -------------------------------------------------------------------------------
rollback() {
  local reason=$1 deadline n=0
  case ${PHASE:-} in rolling_back | rolled_back | rollback_failed) return 0 ;; esac
  trap '' TERM INT HUP # finish the rollback even if asked to stop again
  cf_phase rolling_back
  cf_log "ROLLBACK: $reason"
  # --prune also removes units this upgrade added (for example the auth proxy)
  cf_run ql_install_files "$RUN/previous" "$CF_APP" --prune || cf_log "restoring the previous unit files failed"
  # shellcheck disable=SC2086 # PREV_UNITS is a word list
  cf_run ql_apply_units "$CF_APP" $PREV_UNITS || cf_log "restarting the previous units failed"
  deadline=$(($(date +%s) + RESTORE_TIMEOUT))
  while (($(date +%s) < deadline)); do
    if systemctl --user is-active --quiet "$NEW_UNIT" && cf_gui_ok "$GUI_PORT"; then
      n=$(cf_ready_conns)
      [[ $BASELINE_TUNNEL != 1 ]] && n=1
      ((n >= 1)) && break
    fi
    sleep "$POLL"
  done
  if ((n >= 1)); then
    cf_phase rolled_back
    cf_result "ROLLED_BACK ($reason); the previous units are installed and running again"
    exit 2
  fi
  cf_phase rollback_failed
  cf_result "ROLLBACK_FAILED ($reason): the previous units are installed but not serving. Check: journalctl --user -u $NEW_UNIT -n 100"
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
  trap '' PIPE
  cf_phase pre
  trap 'on_exit $?' EXIT
  trap 'cf_log "signal received"; exit 143' TERM INT HUP
  unset QL_HOLD_UNITS # this watchdog is the one place that restarts the tunnel unit
  ql_lock "$CF_APP"

  cf_phase installing
  cf_run ql_install_files "$RUN/new" "$CF_APP" || rollback "installing the new units failed"
  cf_phase restarting
  T_DOWN=$(date +%s)
  # shellcheck disable=SC2086 # UNITS is a word list
  cf_run ql_apply_units "$CF_APP" $UNITS || rollback "restarting $UNITS failed"
  cf_gate_and_soak rollback
  cf_phase committed
  cf_result "SUCCESS: $UNITS upgraded and serving; the previous units are kept in $RUN/previous"
  exit 0
}

cmd_manual_rollback() {
  RUN=$(run_arg "${1:-}")
  # shellcheck source=/dev/null
  . "$RUN/run.env"
  CF_LOG=$RUN/watchdog.log
  if systemctl --user is-active --quiet "woow-cf-tunnel-upgrade-${RUN##*/"$PREFIX"-}"; then
    ql_die "the watchdog of $RUN is still running; ask it to roll back with: $0 abort $RUN"
  fi
  [[ -d $RUN/previous ]] || ql_die "$RUN has no previous/ snapshot"
  ql_lock "$CF_APP"
  PHASE=manual
  rollback "manual rollback requested"
}

case ${1:-} in
  -h | --help) usage ;;
  rollback | --rollback) shift; cmd_manual_rollback "${1:-}" ;;
  swap | --swap) shift; cmd_swap "${1:-}" ;;
  status | --status) shift; cf_status "$(run_arg "${1:-}")" ;;
  commit | --commit) shift; r=$(run_arg "${1:-}"); touch "$r/COMMIT"; echo "commit requested ($r)" ;;
  abort | --abort) shift; r=$(run_arg "${1:-}"); touch "$r/ROLLBACK"; echo "rollback requested ($r)" ;;
  __watchdog) shift; cmd_watchdog "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  '' | --*) cmd_prepare "$@" ;;
  *) usage ;;
esac
