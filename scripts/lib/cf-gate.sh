# shellcheck shell=bash
# scripts/lib/cf-gate.sh: the swap watchdog shared by scripts/migrate-legacy.sh and
# scripts/upgrade.sh. Repo-specific; the vendored shared lib is quadlet-lib.sh.
#
# Both scripts prepare a RUN dir in the foreground (checks, backup, baseline), then hand
# the risky part to a detached `systemd-run --user` watchdog. The watchdog runs a frozen
# copy of the scripts from $RUN/bin, so a checkout change mid-run cannot affect it:
#   swap (script-specific) -> gate -> soak -> commit
# Any failure, timeout, signal or crash before "committed" calls the script's rollback.
#
# The tunnel token is never read or printed: only hostnames, HTTP codes and counters.
# Settings (the foreground records them in $RUN/run.env for the watchdog):
#   NEW_UNIT NEW_CONTAINER GUI_PORT METRICS_ADDR EXPECT_CONNS GATE_TIMEOUT SOAK_SECONDS
#   POLL SOAK_POLL CURL_PUBLIC_TIMEOUT EXTRA_UNITS HTTP_OVERRIDES

# shellcheck disable=SC2034 # used by the scripts that source this file
CF_APP=woow-cf-tunnel
: "${NEW_UNIT:=woow-cf-tunnel.service}"
: "${NEW_CONTAINER:=woow-cf-tunnel}"
: "${GUI_PORT:=18000}"
: "${METRICS_ADDR:=127.0.0.1:20241}"
: "${EXPECT_CONNS:=4}"
: "${GATE_TIMEOUT:=180}"
: "${SOAK_SECONDS:=600}"
: "${POLL:=5}"
: "${SOAK_POLL:=20}"
: "${CURL_PUBLIC_TIMEOUT:=15}"
: "${EXTRA_UNITS:=}"
: "${HTTP_OVERRIDES:=}"
: "${CF_STATE_ROOT:=$HOME/.local/state/woow-cf-tunnel}"
: "${CF_BACKUP_ROOT:=$HOME/backups}"
CF_RUN_VARS="NEW_UNIT NEW_CONTAINER GUI_PORT METRICS_ADDR EXPECT_CONNS GATE_TIMEOUT SOAK_SECONDS POLL SOAK_POLL CURL_PUBLIC_TIMEOUT EXTRA_UNITS HTTP_OVERRIDES CF_STATE_ROOT CF_BACKUP_ROOT"

# ---- logging: stdout (the journal of the transient unit) + $CF_LOG -------------------------
CF_LOG=''
cf_log() {
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [${PHASE:-cli}] $*"
  echo "$line"
  [[ -z $CF_LOG ]] || echo "$line" >>"$CF_LOG"
}
# cf_run <cmd...>: run it in a subshell (a lib ql_die cannot end the watchdog), fold its
# output into the log, return its status
cf_run() {
  local out rc=0 l
  out=$("$@" 2>&1) || rc=$?
  if [[ -n $out ]]; then while IFS= read -r l; do cf_log "  $l"; done <<<"$out"; fi
  return "$rc"
}
cf_phase() {
  PHASE=$1
  echo "$PHASE" >"$RUN/PHASE"
  cf_log "phase -> $PHASE"
}
cf_result() {
  echo "$1" >"$RUN/RESULT"
  cf_log "RESULT: $1"
}

# ---- probes (stdout = value) ------------------------------------------------------------------
# _cf_metrics <path>: GET cloudflared's metrics server. Empty output -- never a failure --
# when nothing answers there, which is the normal state of an unconfigured, stopped or
# crashed tunnel. The `|| true` is load-bearing: the callers run under `set -euo pipefail`,
# where curl's transport status (7 = connection refused) wins the pipeline and would kill
# them silently instead of letting each probe below return the sentinel it documents.
_cf_metrics() { curl -s -m 4 "http://$METRICS_ADDR/$1" 2>/dev/null || true; }
cf_ready_conns() { # readyConnections from cloudflared /ready; 0 when unreachable
  _cf_metrics ready | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("readyConnections") or 0))
except Exception: print(0)'
}
cf_config_version() { # remote-managed ingress config version; -1 when unknown
  _cf_metrics config | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin)["version"]))
except Exception: print(-1)'
}
cf_ingress_map() { # sorted "hostname origin" lines (no credentials in there)
  _cf_metrics config | python3 -c 'import json,sys
try:
    for r in json.load(sys.stdin)["config"]["ingress"]:
        print(r.get("hostname", "*"), r.get("service", ""))
except Exception:
    pass' | LC_ALL=C sort
}
cf_gui_ok() { [[ $(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://127.0.0.1:${1:-$GUI_PORT}/api/health" 2>/dev/null) == 200 ]]; }
cf_public_code() {
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' -m "$CURL_PUBLIC_TIMEOUT" "https://$1/" 2>/dev/null) || true
  [[ $c =~ ^[0-9]{3}$ ]] || c=000
  printf '%s' "$c"
}
cf_nrestarts() {
  local n
  n=$(systemctl --user show -p NRestarts --value "$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}
cf_port_busy() { [[ -n $(ss -ltnH "( sport = :$1 )" 2>/dev/null) ]]; }
cf_health() { podman inspect -f '{{.State.Health.Status}}' "$NEW_CONTAINER" 2>/dev/null; }
# cf_session_rides_tunnel: this SSH session arrives through cloudflared (loopback source)
cf_session_rides_tunnel() {
  local src=${SSH_CONNECTION:-}
  src=${src%% *}
  [[ $src == 127.0.0.1 || $src == ::1 ]]
}

# ---- baseline -------------------------------------------------------------------------------
# cf_baseline <run> <require_tunnel:0|1>: record the config version, the hostname->origin
# map (+ sha256), readyConnections and each public hostname's HTTP code. Sets
# BASELINE_TUNNEL/VERSION/INGRESS_SHA. Returns 1 on a vacuous or tunnel-down baseline
# (when require_tunnel=1, or when a tunnel is up).
cf_baseline() {
  local run=$1 require=$2 n v host code o nh
  n=$(cf_ready_conns)
  echo "$n" >"$run/ready_conns"
  cf_ingress_map >"$run/ingress.txt"
  sha256sum <"$run/ingress.txt" | cut -d' ' -f1 >"$run/ingress.sha256"
  v=$(cf_config_version)
  echo "$v" >"$run/config_version"
  : >"$run/http_baseline.tsv"
  BASELINE_VERSION=$v
  BASELINE_INGRESS_SHA=$(<"$run/ingress.sha256")
  if ((n < 1)); then
    if ((require)); then echo "  FAIL  cloudflared has no edge connections (http://$METRICS_ADDR/ready)"; return 1; fi
    BASELINE_TUNNEL=0
    echo "  no edge connections now: the gate checks the unit, the GUI and podman health only"
    return 0
  fi
  BASELINE_TUNNEL=1
  while read -r host _; do
    [[ $host == "*" ]] && continue
    code=$(cf_public_code "$host")
    for o in $HTTP_OVERRIDES; do
      if [[ ${o%%=*} == "$host" ]]; then
        echo "  override $host: baseline $code, expect ${o#*=}"
        code=${o#*=}
      fi
    done
    printf '%s\t%s\n' "$host" "$code" >>"$run/http_baseline.tsv"
  done <"$run/ingress.txt"
  nh=$(grep -vc '^\*' "$run/ingress.txt" || true)
  echo "  config version $v, $nh public hostname(s), readyConnections=$n"
  sed 's/^/    /' "$run/http_baseline.tsv"
  # A vacuous baseline (unreadable /config) would let the gate pass without checking anything.
  ((v >= 0)) || { echo "  FAIL  cannot read the ingress config version from http://$METRICS_ADDR/config"; return 1; }
  ((nh >= 1)) || { echo "  FAIL  the ingress map is empty; nothing to verify against"; return 1; }
  if grep -qE $'\t(000|530)$' "$run/http_baseline.tsv"; then
    echo "  FAIL  a hostname already returns 000/530 (tunnel down?) before the swap"
    return 1
  fi
  return 0
}

# ---- gate + soak (watchdog) -----------------------------------------------------------------
# cf_gate_check: sets GATE_FAIL and returns 1 on the first failing check
cf_gate_check() {
  local u n v s hs host want got bad=''
  GATE_FAIL=''
  systemctl --user is-active --quiet "$NEW_UNIT" || { GATE_FAIL="$NEW_UNIT not active"; return 1; }
  for u in $EXTRA_UNITS; do
    systemctl --user is-active --quiet "$u" || { GATE_FAIL="$u not active"; return 1; }
  done
  cf_gui_ok "$GUI_PORT" || { GATE_FAIL="GUI /api/health on 127.0.0.1:$GUI_PORT is not 200"; return 1; }
  if [[ $BASELINE_TUNNEL == 1 ]]; then
    n=$(cf_ready_conns)
    ((n >= EXPECT_CONNS)) || { GATE_FAIL="readyConnections=$n (want $EXPECT_CONNS)"; return 1; }
    if [[ -z ${T_UP:-} ]]; then
      T_UP=$(date +%s)
      cf_log "tunnel ready ($n connections); outage ~$((T_UP - T_DOWN))s"
    fi
    v=$(cf_config_version)
    [[ $v == "$BASELINE_VERSION" ]] || { GATE_FAIL="config version $v != baseline $BASELINE_VERSION"; return 1; }
    s=$(cf_ingress_map | sha256sum | cut -d' ' -f1)
    [[ $s == "$BASELINE_INGRESS_SHA" ]] || { GATE_FAIL="the ingress hostname map changed"; return 1; }
  fi
  # Read the scheduled check's result; a manual `podman healthcheck run` would count
  # toward the failing streak and could trigger HealthOnFailure=kill early.
  hs=$(cf_health)
  [[ $hs == healthy ]] || { GATE_FAIL="podman health '${hs:-none}' (the first scheduled check runs ~30s after start)"; return 1; }
  if [[ $BASELINE_TUNNEL == 1 ]]; then
    while IFS=$'\t' read -r host want; do
      got=$(cf_public_code "$host")
      [[ $got == "$want" ]] || bad+=" $host:$got(want $want)"
    done <"$RUN/http_baseline.tsv"
    [[ -z $bad ]] || { GATE_FAIL="public hostnames differ:$bad"; return 1; }
  fi
  return 0
}

# cf_gate_and_soak <rollback_fn>: gate until it passes (else rollback at GATE_TIMEOUT), then
# soak SOAK_SECONDS. rollback_fn REASON must not return.
cf_gate_and_soak() {
  local rb=$1 deadline restarts0 soak_end misses=0 n
  restarts0=$(cf_nrestarts "$NEW_UNIT")
  cf_phase gating
  deadline=$(($(date +%s) + GATE_TIMEOUT))
  until cf_gate_check; do
    [[ -e $RUN/ROLLBACK ]] && "$rb" "operator abort"
    (($(date +%s) >= deadline)) && "$rb" "gate timeout after ${GATE_TIMEOUT}s: $GATE_FAIL"
    cf_log "waiting: $GATE_FAIL"
    sleep "$POLL"
  done
  if [[ $BASELINE_TUNNEL == 1 ]]; then
    cf_log "gate passed: unit active, GUI ok, $EXPECT_CONNS connections, config v$BASELINE_VERSION, hostname map unchanged, healthy, all public codes match"
  else
    cf_log "gate passed: unit active, GUI ok, healthy (no tunnel was connected before)"
  fi
  cf_phase soaking
  soak_end=$(($(date +%s) + SOAK_SECONDS))
  while (($(date +%s) < soak_end)) && [[ ! -e $RUN/COMMIT ]]; do
    [[ -e $RUN/ROLLBACK ]] && "$rb" "operator abort during soak"
    systemctl --user is-active --quiet "$NEW_UNIT" || "$rb" "$NEW_UNIT inactive during soak"
    [[ $(cf_nrestarts "$NEW_UNIT") == "$restarts0" ]] || "$rb" "$NEW_UNIT restarted during soak (health kill or crash)"
    if [[ $BASELINE_TUNNEL == 1 ]]; then
      n=$(cf_ready_conns)
      if ((n >= 1)); then misses=0; else
        misses=$((misses + 1))
        cf_log "soak: readyConnections=0 ($misses/3)"
      fi
      ((misses < 3)) || "$rb" "tunnel not ready for 3 consecutive soak checks"
    fi
    sleep "$SOAK_POLL"
  done
  [[ ! -e $RUN/COMMIT ]] || cf_log "soak ended early (commit)"
  return 0
}

# ---- run dirs, freeze, detach ---------------------------------------------------------------
# cf_new_run <prefix>: create $CF_STATE_ROOT/<prefix>-<stamp> (0700); prints it
cf_new_run() {
  local base run i=2
  base=$CF_STATE_ROOT/$1-$(date +%Y%m%d-%H%M%S)
  (umask 077 && mkdir -p "$CF_STATE_ROOT") || return 1
  run=$base
  until (umask 077 && mkdir "$run" 2>/dev/null); do
    run=$base-$i
    i=$((i + 1))
    ((i < 100)) || return 1
  done
  printf '%s' "$run"
}
# cf_latest_run <prefix>: newest $CF_STATE_ROOT/<prefix>-* ("" when none)
cf_latest_run() {
  local d last=''
  for d in "$CF_STATE_ROOT/$1"-*; do [[ -d $d ]] && last=$d; done
  printf '%s' "$last"
}
# cf_write_run_env <run> <VAR...>: record settings for the watchdog (printf %q, sourced back)
cf_write_run_env() {
  local run=$1 v
  shift
  for v in $CF_RUN_VARS "$@"; do printf '%s=%q\n' "$v" "${!v-}"; done >"$run/run.env"
  chmod 600 "$run/run.env"
}
# cf_freeze <run> <script>: the watchdog runs this copy (and these libs), not the checkout
cf_freeze() {
  local run=$1 script=$2 dir
  dir=$(cd "$(dirname "$script")" && pwd -P)
  mkdir -p "$run/bin/lib"
  cp -p "$script" "$run/bin/"
  cp -p "$dir/lib/quadlet-lib.sh" "$dir/lib/cf-gate.sh" "$run/bin/lib/"
  chmod 700 "$run/bin" "$run/bin/${script##*/}"
}
# cf_detach <run> <unit> <script-name> <description>
cf_detach() {
  # Hand the app lock over: the watchdog takes it, and a transient unit does not
  # inherit our file descriptors.
  if [[ -n ${QL_LOCK_FD:-} ]]; then
    eval "exec ${QL_LOCK_FD}>&-"
    QL_LOCK_FD=''
  fi
  # KillMode=mixed: stopping the unit SIGTERMs only the script, whose trap then rolls
  # back; the commands it runs are not killed mid-rollback.
  systemd-run --user --collect --unit="$2" --description="$4" \
    --property=KillMode=mixed --property=TimeoutStopSec=300 \
    "$1/bin/$3" __watchdog "$1"
}
cf_status() {
  local run=$1
  echo "run:    $run"
  echo "phase:  $(cat "$run/PHASE" 2>/dev/null || echo '<not started>')"
  echo "result: $(cat "$run/RESULT" 2>/dev/null || echo '<running or not started>')"
  tail -n 25 "$run/watchdog.log" 2>/dev/null
}
