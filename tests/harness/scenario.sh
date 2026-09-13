#!/usr/bin/env bash
# tests/harness/scenario.sh: run one migrate-legacy.sh or upgrade.sh scenario against the
# mocks and print its outcome (phase, result, end state). Called by run-all.sh; usable on
# its own for debugging:
#
#   HARNESS_TMP=$(mktemp -d) tests/harness/scenario.sh migrate happy direct
#
#   scenario.sh migrate <scenario> <mode>   modes: direct swap sigterm abort
#                                                  soak_restart soak_lost postcommit_rollback
#   scenario.sh upgrade <scenario> <mode>   modes: direct swap
# Scenarios pick the mock behaviour: happy, never_ready, version_changed, public_mismatch,
# unhealthy, broken_config, legacy_unhealthy, tunnel_session, tailnet_session, openclaw,
# bad_image, noop.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$HERE/common.sh"
kind=$1 sc=$2 mode=${3:-direct}
old_image='' new_image=''
snapshot_repo
sandbox "$kind-$sc-$mode"
export MOCK_SCENARIO=$sc
# Short timings: the gate and soak logic is what is under test, not the clock.
export GATE_TIMEOUT=8 POLL=1 SOAK_SECONDS=${SOAKS:-4} SOAK_POLL=1 LEGACY_READY_TIMEOUT=6 \
  RESTORE_TIMEOUT=6 CURL_PUBLIC_TIMEOUT=1 EXPECT_CONNS=4 MOCK_WARMUP=2
RUN=''

wait_phase() { # wait_phase <phase> <run>
  local n=0
  while ((n++ < 80)); do
    [[ $(cat "$2/PHASE" 2>/dev/null) == "$1" ]] && return 0
    sleep 0.25
  done
  return 1
}
wait_pid() { while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; }

report() {
  local q
  q=$(QDIR)
  printf '  phase=%s\n  result=%s\n' "$(cat "$RUN/PHASE" 2>/dev/null)" "$(cat "$RUN/RESULT" 2>/dev/null)"
  printf '  end: legacy_active=%s legacy_enabled=%s new_active=%s auth_active=%s quadlet_files=[%s] legacy_unit_file=%s image=%s backups=%s\n' \
    "$(cat "$MOCK_STATE/legacy_active" 2>/dev/null || echo -)" \
    "$(cat "$MOCK_STATE/legacy_enabled" 2>/dev/null || echo -)" \
    "$(cat "$MOCK_STATE/units/woow-cf-tunnel.service/active" 2>/dev/null || echo 0)" \
    "$(cat "$MOCK_STATE/units/woow-cf-tunnel-auth.service/active" 2>/dev/null || echo 0)" \
    "$(find "$q" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)" \
    "$([[ -e $HOME/.config/systemd/user/cf-tunnel-webgui.service ]] && echo kept || echo MISSING)" \
    "$(cat "$MOCK_STATE/running_image" 2>/dev/null || echo -)" \
    "$(find "$HOME/backups" -name '*.tar' 2>/dev/null | wc -l)"
  if [[ $kind == upgrade ]]; then
    lbl() {
      case $1 in "$old_image") echo old ;; "$new_image") echo new ;; *) echo "other($1)" ;; esac
    }
    printf '  images: running=%s installed=%s\n' \
      "$(lbl "$(cat "$MOCK_STATE/running_image" 2>/dev/null)")" \
      "$(lbl "$(sed -n 's/^Image=//p' "$q/woow-cf-tunnel.container" 2>/dev/null)")"
  fi
  grep -hE 'outage|waiting|ROLLBACK' "$RUN/watchdog.log" 2>/dev/null | head -n 3 | sed 's/^/  log: /'
}

# ---- migrate ---------------------------------------------------------------------------------
if [[ $kind == migrate ]]; then
  legacy_host
  env_file
  pf_args=(--allow-dirty)
  if [[ $sc == openclaw ]]; then
    # openclaw: persistent legacy container, GUI on 8888, compose-named volume, auth proxy
    # taking over the port the public hostname already points at
    export MOCK_PERSIST=1 MOCK_LEGACY_VOL=woow_cloudflare_tunnel_webgui_cf_data \
      LEGACY_UNIT=podman-cf-tunnel-webgui.service LEGACY_GUI_PORT=8888 \
      HTTP_OVERRIDES="gui.example.io=401" RESCUE_CONTAINER=none \
      MOCK_EXTRA_ING='{"hostname":"gui.example.io","service":"http://localhost:8888"},'
    set_env CF_DATA_VOLUME woow_cloudflare_tunnel_webgui_cf_data
    printf '[Unit]\nDescription=legacy\n[Service]\nExecStart=/usr/bin/podman start -a cf-tunnel-webgui\n[Install]\nWantedBy=default.target\n' \
      >"$HOME/.config/systemd/user/podman-cf-tunnel-webgui.service"
    echo 'correct-horse-battery' | bash "$R/scripts/auth-passwd.sh" admin >/dev/null
    pf_args+=(--with-auth)
  fi
  # Both of these arrive from 127.0.0.1 (tailscaled runs --tun=userspace-networking, so it
  # re-dials sshd over loopback just like cloudflared does): only the carrier tells them apart.
  [[ $sc == tunnel_session ]] && export SSH_CONNECTION="127.0.0.1 50642 127.0.0.1 22" MOCK_SSH_CARRIER=cloudflared
  [[ $sc == tailnet_session ]] && export SSH_CONNECTION="127.0.0.1 55996 127.0.0.1 22" MOCK_SSH_CARRIER=tailscaled
  pf=$(bash "$R/scripts/migrate-legacy.sh" preflight "${pf_args[@]}" 2>&1)
  RUN=$(sed -n 's/^preflight OK. RUN=//p' <<<"$pf")
  if [[ -z $RUN ]]; then
    echo "  preflight refused"
    grep -E 'FAIL|problem|ERROR' <<<"$pf" | head -n 4 | sed 's/^/    /'
    exit 0
  fi
  # the legacy tunnel dies between preflight and swap
  [[ $sc == legacy_unhealthy ]] && echo 0 >"$MOCK_STATE/legacy_active"
  script=$RUN/bin/migrate-legacy.sh
else
  # ---- upgrade -------------------------------------------------------------------------------
  env_file
  bash "$R/scripts/install.sh" --allow-dirty >/dev/null 2>&1 || { echo "  setup install failed"; exit 1; }
  echo 10 >"$MOCK_STATE/new_ready_calls" # the pre-upgrade tunnel is warmed up
  old_image=$(image_ref)
  [[ $sc != noop ]] && new_commit "upgrade-$sc"
  new_image=$(image_ref)
  if [[ $sc == bad_image ]]; then
    MOCK_BAD_IMAGE=$(image_ref)
    export MOCK_BAD_IMAGE
  fi
  up=$(bash "$R/scripts/upgrade.sh" --prepare-only 2>&1)
  RUN=$(sed -n 's/^upgrade: RUN=//p' <<<"$up")
  if [[ -z $RUN ]]; then
    echo "  no upgrade run started (old=$old_image)"
    grep -E 'up to date|ERROR|FAIL' <<<"$up" | head -n 4 | sed 's/^/    /'
    exit 0
  fi
  script=$RUN/bin/upgrade.sh
fi

case $mode in
  direct) bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1 ;;
  swap)
    bash "$R/scripts/$([[ $kind == migrate ]] && echo migrate-legacy.sh || echo upgrade.sh)" swap "$RUN" >/dev/null 2>&1
    wait_pid "$(cat "$MOCK_STATE/detached.pid")" ;;
  postcommit_rollback)
    bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1
    echo "  (watchdog result: $(cat "$RUN/RESULT"))"
    bash "$R/scripts/$([[ $kind == migrate ]] && echo migrate-legacy.sh || echo upgrade.sh)" --rollback "$RUN" >>"$RUN/direct.log" 2>&1 ;;
  sigterm | abort | soak_restart | soak_lost)
    bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1 &
    pid=$!
    want=gating
    [[ $mode == soak_* ]] && want=soaking
    wait_phase "$want" "$RUN" || echo "  never reached phase $want"
    case $mode in
      sigterm) kill -TERM "$pid" ;;
      abort) bash "$R/scripts/$([[ $kind == migrate ]] && echo migrate-legacy.sh || echo upgrade.sh)" abort "$RUN" >/dev/null ;;
      soak_restart) echo 1 >"$MOCK_STATE/new_nrestarts" ;;
      soak_lost) touch "$MOCK_STATE/soaking" ;;
    esac
    wait "$pid" ;;
esac
report
