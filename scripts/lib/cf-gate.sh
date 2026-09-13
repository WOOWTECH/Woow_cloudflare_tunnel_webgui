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
        # cloudflared sends the catch-all as {"hostname": "", ...}: the key is
        # present and empty, so a dict default would never fire. An "or" catches both.
        print(r.get("hostname") or "*", r.get("service", ""))
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
# ---- which remote-access path is this session on? --------------------------------------------
# The client address in SSH_CONNECTION does NOT tell the two paths apart. tailscaled runs with
# --tun=userspace-networking on these hosts, so it terminates the tailnet connection itself and
# re-dials 127.0.0.1:22: a tailnet session is as loopback as a cloudflared one. What differs is
# which local process holds the *client* end of that loopback pair (measured on toypark1234):
#   tailnet      ESTAB 127.0.0.1:52500 127.0.0.1:22 users:(("tailscaled",pid=3602652,fd=16))
#   cloudflared  ESTAB 127.0.0.1:52512 127.0.0.1:22 users:(("cloudflared",pid=3909,fd=12))
# so the carrier process names the path, and `ss -tnpH "sport = :<client_port>"` finds it.
: "${CF_PROC:=/proc}"
# A carrier is the tunnel when its process name, argv[0], cgroup (Quadlet unit) or podman
# container name matches this: cloudflared itself, the Quadlet unit/container woow-cf-tunnel,
# or the legacy cf-tunnel-webgui container it runs in here.
: "${CF_CARRIER_TUNNEL_RE:=cloudflared|cf-tunnel|woow-cf-tunnel}"
# Carriers that only front another process (rootless podman port shims): never conclusive.
: "${CF_CARRIER_OPAQUE_RE:=^(pasta|passt|slirp4netns|rootlessport|conmon|podman)$}"
# shellcheck disable=SC2034 # CF_SESSION_PATH/WHY are read by the scripts that source this file
CF_SESSION_PATH='' # tunnel | other | unknown | none, set by cf_session_rides_tunnel
CF_SESSION_WHY=''  # one line saying what was seen, so a refusal is never a guess to the operator

_cf_is_loopback() { [[ $1 == 127.* || $1 == ::1 || $1 == 0:0:0:0:0:0:0:1 || $1 == ::ffff:127.* ]]; }
# _cf_argv0 <pid>: argv[0] only. The rest of the command line is never read, let alone
# printed: cloudflared's carries the tunnel token.
_cf_argv0() {
  local a=''
  IFS= read -r -d '' a <"$CF_PROC/$1/cmdline" 2>/dev/null
  printf '%s' "$a"
}
# _cf_sshd_ancestor: is this shell a descendant of sshd? (OpenSSH >= 9.8 splits the session
# into sshd-session, hence the prefix match.) Used only when SSH_CONNECTION is missing.
_cf_sshd_ancestor() {
  local pid=${CF_SESSION_PID:-$$} n=0 comm st ppid
  while ((n++ < 20)); do
    comm=$(cat "$CF_PROC/$pid/comm" 2>/dev/null) || return 1
    [[ $comm == sshd* ]] && return 0
    st=$(cat "$CF_PROC/$pid/stat" 2>/dev/null) || return 1
    read -r _ ppid _ <<<"${st##*') '}" # pid (comm) state ppid ...; comm may hold spaces
    [[ ${ppid:-} =~ ^[0-9]+$ ]] && ((ppid > 1)) || return 1
    pid=$ppid
  done
  return 1
}
# _cf_carriers <sport> <dport>: "<comm> <pid>" per local process holding the client end of
# the loopback pair. No output = undeterminable (no ss, no socket, or no permission to see
# whose it is -- ss omits users:(()) for another user's process).
_cf_carriers() {
  local sport=$1 dport=${2:-} out='' line la pa rest lport laddr pport
  command -v ss >/dev/null 2>&1 || return 0
  out=$(ss -tnpH "sport = :$sport" 2>/dev/null) || out=''
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    read -r _ _ _ la pa rest <<<"$line" # State Recv-Q Send-Q Local Peer Process
    lport=${la##*:} laddr=${la%:*} pport=${pa##*:}
    laddr=${laddr#\[} laddr=${laddr%\]}
    [[ $lport == "$sport" ]] || continue
    [[ -z $dport || $pport == "$dport" ]] || continue
    _cf_is_loopback "$laddr" || continue
    while [[ $rest =~ \(\"([^\"]+)\",pid=([0-9]+) ]]; do
      printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
  done <<<"$out"
}
# _cf_carrier_kind <comm> <pid>: tunnel | opaque | other
_cf_carrier_kind() {
  local comm=$1 pid=$2 argv0 cg name
  if [[ $comm =~ $CF_CARRIER_TUNNEL_RE ]]; then printf tunnel; return 0; fi
  # comm is truncated at 15 characters and says nothing about the container the carrier runs
  # in, so widen the evidence: argv[0], the cgroup path (a Quadlet carrier shows up there as
  # <unit>.service) and, for a podman container, the container's name (the cgroup only
  # carries its id).
  argv0=$(_cf_argv0 "$pid")
  cg=$(cat "$CF_PROC/$pid/cgroup" 2>/dev/null) || cg=''
  if [[ ${argv0##*/} =~ $CF_CARRIER_TUNNEL_RE || $cg =~ $CF_CARRIER_TUNNEL_RE ]]; then printf tunnel; return 0; fi
  if [[ $cg =~ libpod(-payload)?-([0-9a-f]{12,}) ]]; then
    name=$(podman inspect -f '{{.Name}}' "${BASH_REMATCH[2]}" 2>/dev/null) || name=''
    if [[ -n $name && $name =~ $CF_CARRIER_TUNNEL_RE ]]; then printf tunnel; return 0; fi
  fi
  if [[ $comm =~ $CF_CARRIER_OPAQUE_RE ]]; then printf opaque; return 0; fi
  printf other
}
# cf_session_rides_tunnel: would cutting the tunnel cut this shell's own SSH session?
# Sets CF_SESSION_PATH and CF_SESSION_WHY (the callers put WHY in their message).
#
# This is a safety guard, so it is deliberately asymmetric: a wrong "no" lets an operator cut
# the branch they are sitting on, while a wrong "yes" only costs them --allow-tunnel-session
# or --force. Every case where the carrier cannot be determined -- no ss(8), no permission to
# see the carrier's process, a container shim that could be fronting cloudflared, two
# different carriers on one socket, or an SSH_CONNECTION stripped by sudo/su/tmux under an
# sshd parent -- therefore answers "yes, assume it rides the tunnel".
# The one negative answer given without evidence of a carrier is "not an ssh session at all"
# (no SSH_CONNECTION and no sshd ancestor: a console, CI, or a detached multiplexer, none of
# which a tunnel restart can disconnect).
cf_session_rides_tunnel() {
  local conn=${SSH_CONNECTION:-} src sport dport carriers='' comm pid k desc=''
  local -a kinds=() comms=()
  CF_SESSION_PATH='' CF_SESSION_WHY=''
  if [[ -z $conn ]]; then
    if _cf_sshd_ancestor; then
      CF_SESSION_PATH=unknown
      CF_SESSION_WHY="SSH_CONNECTION is unset but this shell descends from sshd (sudo, su or a multiplexer strips it), so the access path cannot be read"
      return 0
    fi
    CF_SESSION_PATH=none
    CF_SESSION_WHY="no SSH_CONNECTION and no sshd parent process: this is not an ssh session that a tunnel restart could drop"
    return 1
  fi
  read -r src sport _ dport <<<"$conn" # <client_ip> <client_port> <server_ip> <server_port>
  if ! _cf_is_loopback "${src:-}"; then
    CF_SESSION_PATH=other
    CF_SESSION_WHY="the ssh client address ${src:-?} is not loopback, so no local forwarder carries this session"
    return 1
  fi
  if [[ ! ${sport:-} =~ ^[0-9]+$ ]]; then
    CF_SESSION_PATH=unknown
    CF_SESSION_WHY="the client address $src is loopback and SSH_CONNECTION ('$conn') has no client port to look the carrier up by"
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    CF_SESSION_PATH=unknown
    CF_SESSION_WHY="the client address $src is loopback (both the tunnel and the tailnet look like this) and ss(8) is missing, so the carrier cannot be identified"
    return 0
  fi
  carriers=$(_cf_carriers "$sport" "${dport:-}")
  if [[ -z $carriers ]]; then
    CF_SESSION_PATH=unknown
    CF_SESSION_WHY="the client address $src is loopback but ss shows no process holding $src:$sport (it belongs to another user, or the socket is gone)"
    return 0
  fi
  while read -r comm pid; do
    [[ -n ${comm:-} ]] || continue
    k=$(_cf_carrier_kind "$comm" "$pid")
    desc+="${desc:+, }$comm (pid $pid)"
    [[ " ${kinds[*]} " == *" $k "* ]] || kinds+=("$k")
    [[ " ${comms[*]} " == *" $comm "* ]] || comms+=("$comm")
  done <<<"$carriers"
  if [[ " ${kinds[*]} " == *" tunnel "* ]]; then
    CF_SESSION_PATH=tunnel
    CF_SESSION_WHY="the local end of this session ($src:$sport) is held by $desc: it arrives through the cloudflared tunnel"
    return 0
  fi
  # a shim that could be fronting cloudflared, or two different carriers on one socket
  if [[ " ${kinds[*]} " == *" opaque "* ]] || ((${#comms[@]} > 1)); then
    CF_SESSION_PATH=unknown
    CF_SESSION_WHY="the local end of this session ($src:$sport) is held by $desc, which cannot be told apart from cloudflared fronting it"
    return 0
  fi
  CF_SESSION_PATH=other
  CF_SESSION_WHY="the local end of this session ($src:$sport) is held by $desc, not cloudflared: this session does not ride the tunnel"
  return 1
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

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -------------------------
# The swap does not rename the legacy container: the new Quadlet container has a different
# name, so it simply leaves the legacy one stopped, with its unit disabled but kept. That is
# a rollback path only while nothing starts the container again. The user unit
# podman-restart.service runs `podman start --all --filter restart-policy=always` at boot, so
# where it is enabled and the legacy container's policy is exactly `always`, a reboot brings
# a second cloudflared up on the same tunnel token, the same `/data` volume and the same host
# ports (the legacy container is --network=host) next to the Quadlet one. podman 4.9.3 cannot
# change a restart policy afterwards, so there the container is captured and removed instead,
# and the rollback recreates it before it starts the legacy unit. ql_rollback_strategy asks
# this host's real state, never its name.

# cf_legacy_capture <backup dir> <container>: write the rollback copy. Read-only towards the
# container, so preflight runs it while the legacy tunnel still serves: a container the
# library cannot replay (an empty CreateCommand - created through the podman API rather than
# the CLI) is refused there, not in the middle of the swap. No --commit: the GUI keeps its
# settings, its tunnel token and its credentials in the /data volume, and the live container's
# writable layer is __pycache__ only.
cf_legacy_capture() {
  local bk=${1:?usage: cf_legacy_capture <backup dir> <container>} c=${2:?} meta
  meta=$bk/legacy-container/$c/meta
  if [[ -f $meta ]]; then
    ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
  else
    ql_capture_container "$c" "$bk" >/dev/null
  fi
  [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
    "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy container can simply be left stopped) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
}

# cf_legacy_remove <backup dir> <container>: the capture path's half of the swap. Returns 1
# rather than dying, because inside the watchdog a failure has to roll back.
cf_legacy_remove() {
  local bk=${1:?} c=${2:?}
  if [[ ! -f $bk/legacy-container/$c/meta ]]; then
    cf_log "no rollback copy of $c in $bk; refusing to remove it"
    return 1
  fi
  # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes the capture
  # records and expects to find again.
  podman rm "$c" >/dev/null 2>&1 || { cf_log "podman rm $c failed"; return 1; }
  cf_log "removed the legacy container $c; the rollback recreates it from $bk/legacy-container/$c"
}

# cf_legacy_restore <backup dir> <container>: make sure the legacy container exists again
# before its unit is started. A no-op on the path that only left it stopped.
cf_legacy_restore() {
  local bk=${1:-} c=${2:?}
  if podman container exists "$c" >/dev/null 2>&1; then return 0; fi
  if [[ -n $bk && -f $bk/legacy-container/$c/meta ]]; then
    if ql_recreate_container "$bk" "$c" >/dev/null; then
      cf_log "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
      return 0
    fi
    cf_log "could not recreate $c from $bk/legacy-container/$c; $LEGACY_UNIT will fail to start"
    return 1
  fi
  cf_log "the legacy container $c does not exist and there is no rollback copy in ${bk:-<none>}"
  return 1
}
