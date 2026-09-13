#!/usr/bin/env bash
# tests/cf-gate-session.sh: unit tests for cf_session_rides_tunnel (scripts/lib/cf-gate.sh),
# the guard that stops an operator cutting the branch they are sitting on.
#
# A loopback client address is NOT a discriminator here: tailscaled runs with
# --tun=userspace-networking, so a tailnet session arrives from 127.0.0.1 exactly like a
# cloudflared one. The guard therefore asks which local process holds the client end of the
# loopback pair. Everything is driven by stubs (an `ss` on PATH, a fake /proc via CF_PROC, a
# fake `podman`), so this needs no tunnel, no tailnet and no network: it runs in CI.
#
# The lines the stubs replay are the ones measured on toypark1234:
#   tailnet      ESTAB 127.0.0.1:55996 127.0.0.1:22 users:(("tailscaled",pid=3602652,fd=16))
#   cloudflared  ESTAB 127.0.0.1:50642 127.0.0.1:22 users:(("cloudflared",pid=3909,fd=12))
#
#   tests/cf-gate-session.sh [filter]
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-gate-session.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../scripts/lib/cf-gate.sh
. "$REPO/scripts/lib/cf-gate.sh"
filter=${1:-}
fails=0 ran=0

# the carrier's real command line carries the tunnel token; the stubs plant this in argv so
# the assertions below can prove the guard never reads past argv[0].
TOKEN=not-a-real-eyJhIjoiVEVTVC1PTkxZIn0 # shape of a tunnel token, allowlisted in tests/no-secrets.sh

# the stubs are the whole PATH while the guard runs, so the few real tools they need
# (their own interpreter included) are linked in beside them
mkdir -p "$TMP/bin" "$TMP/proc"
for b in bash env cat; do ln -s "$(command -v "$b")" "$TMP/bin/$b"; done
# podman stub: the cgroup of a containerised carrier carries only the container id, so the
# guard resolves the id to a name. MOCK_CTR_NAME=<id>:<name> pairs, ';'-separated.
# `podman inspect -f '{{.Name}}'` prints the bare name (verified on podman 4.9.3); the
# leading-slash spelling this stub used is docker's, which podman never emits.
cat >"$TMP/bin/podman" <<'STUB'
#!/usr/bin/env bash
id=${*: -1}
IFS=';' read -r -a pairs <<<"${MOCK_CTR_NAME:-}"
for p in "${pairs[@]}"; do
  [[ ${p%%:*} == "$id" ]] && { printf '%s\n' "${p#*:}"; exit 0; }
done
exit 1
STUB
chmod +x "$TMP/bin/podman"

# ss_says <line>...: an `ss` stub that replays these lines whatever the filter, so the guard's
# own socket matching (client port, peer port, loopback) is what is under test.
ss_says() {
  { printf '#!/usr/bin/env bash\ncat <<%s\n' "'SSEOF'"; printf '%s\n' "$@"; printf 'SSEOF\n'; } >"$TMP/bin/ss"
  chmod +x "$TMP/bin/ss"
}
no_ss() { rm -f "$TMP/bin/ss"; }
# proc <pid> <comm> <argv0> <cgroup>: a carrier process in the fake /proc
proc() {
  mkdir -p "$TMP/proc/$1"
  printf '%s\n' "$2" >"$TMP/proc/$1/comm"
  printf '%s\0tunnel\0run\0--token\0%s\0' "$3" "$TOKEN" >"$TMP/proc/$1/cmdline"
  printf '%s\n' "$4" >"$TMP/proc/$1/cgroup"
}
# pstat <pid> <comm> <ppid>: a link in the fake process tree walked when SSH_CONNECTION is gone
pstat() {
  mkdir -p "$TMP/proc/$1"
  printf '%s\n' "$2" >"$TMP/proc/$1/comm"
  printf '%s (%s) S %s 0 0 0 0 0\n' "$1" "$2" "$3" >"$TMP/proc/$1/stat"
}
reset_stubs() {
  rm -rf "${TMP:?}/proc"
  mkdir -p "$TMP/proc"
  no_ss
  unset MOCK_CTR_NAME
  export CF_PROC=$TMP/proc CF_SESSION_PID=100
  unset SSH_CONNECTION
}

# case <name> <rides|no> <path>: run the guard with only the stubs on PATH and check the
# verdict, the classification, and that the reason is a real sentence without the token.
case_() {
  local name=$1 want=$2 want_path=$3 rc=0 got old=$PATH bad=''
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  PATH=$TMP/bin
  cf_session_rides_tunnel || rc=$?
  PATH=$old
  got=$( ((rc == 0)) && echo rides || echo no)
  [[ $got == "$want" ]] || bad+=" verdict=$got(want $want)"
  [[ $CF_SESSION_PATH == "$want_path" ]] || bad+=" path=$CF_SESSION_PATH(want $want_path)"
  [[ -n $CF_SESSION_WHY ]] || bad+=' no CF_SESSION_WHY'
  [[ $CF_SESSION_WHY != *"$TOKEN"* ]] || bad+=' CF_SESSION_WHY leaked the token'
  if [[ -z $bad ]]; then
    echo "ok    $name [$CF_SESSION_PATH] $CF_SESSION_WHY"
  else
    echo "FAIL  $name:$bad"
    echo "        why: $CF_SESSION_WHY"
    fails=$((fails + 1))
  fi
}

# 1. cloudflared holds the client end -> it rides the tunnel
reset_stubs
export SSH_CONNECTION="127.0.0.1 50642 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50642 127.0.0.1:22 users:(("cloudflared",pid=3909,fd=12))'
proc 3909 cloudflared /usr/local/bin/cloudflared '0::/user.slice/user-1000.slice/user@1000.service/user.slice/libpod-a787d52f8bf0c78f18f2d902c6cb61ac1c1272c14b6227fd9d1a211493459962.scope/container'
case_ cloudflared-carrier rides tunnel

# 2. tailscaled holds it -> the rescue path, which the old loopback test refused
reset_stubs
export SSH_CONNECTION="127.0.0.1 55996 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:55996 127.0.0.1:22 users:(("tailscaled",pid=3602652,fd=16))'
proc 3602652 tailscaled /usr/sbin/tailscaled '0::/user.slice/user-1000.slice/user@1000.service/app.slice/woow-tailscale.service/libpod-payload-cb0aa3b48c3c968a5a721afae5b17c8edcaa454691628902ca4f429dd861625a'
export MOCK_CTR_NAME='cb0aa3b48c3c968a5a721afae5b17c8edcaa454691628902ca4f429dd861625a:woow-tailscale'
case_ tailscaled-carrier no other

# 3. a carrier whose name says nothing, but which lives in the cf-tunnel-webgui container
reset_stubs
export SSH_CONNECTION="127.0.0.1 50700 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50700 127.0.0.1:22 users:(("cf-proxy-wrapper",pid=4242,fd=9))'
proc 4242 cf-proxy-wrapper /usr/bin/wrapper '0::/user.slice/user-1000.slice/user@1000.service/user.slice/libpod-b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1.scope/container'
export MOCK_CTR_NAME='b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1:cf-tunnel-webgui'
case_ carrier-in-cf-container rides tunnel

# 4. a Quadlet carrier is named by its cgroup even when comm and the container name are not read
reset_stubs
export SSH_CONNECTION="::1 50701 ::1 22"
ss_says 'ESTAB 0      0      [::1]:50701 [::1]:22 users:(("catatonit",pid=4243,fd=9))'
proc 4243 catatonit /usr/bin/catatonit '0::/user.slice/user-1000.slice/user@1000.service/app.slice/woow-cf-tunnel.service/container'
case_ carrier-in-cf-quadlet-unit rides tunnel

# 5. a rootless podman port shim could be fronting cloudflared: undeterminable -> assume yes
reset_stubs
export SSH_CONNECTION="127.0.0.1 50702 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50702 127.0.0.1:22 users:(("pasta",pid=4244,fd=9))'
proc 4244 pasta /usr/bin/pasta '0::/user.slice/user-1000.slice/user@1000.service/init.scope'
case_ opaque-shim-carrier rides unknown

# 6. two different carriers on one socket: ambiguous -> assume yes
reset_stubs
export SSH_CONNECTION="127.0.0.1 50703 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50703 127.0.0.1:22 users:(("tailscaled",pid=4245,fd=9),("socat",pid=4246,fd=7))'
proc 4245 tailscaled /usr/sbin/tailscaled '0::/init.scope'
proc 4246 socat /usr/bin/socat '0::/user.slice'
case_ ambiguous-carriers rides unknown

# 7. a non-loopback client address is nobody's local forwarder
reset_stubs
export SSH_CONNECTION="100.113.239.105 50000 100.112.215.78 22"
ss_says 'ESTAB 0      0      100.112.215.78:22 100.113.239.105:50000 users:(("sshd",pid=1,fd=3))'
case_ non-loopback-source no other

# 8. no ss(8) to ask -> undeterminable -> assume yes
reset_stubs
export SSH_CONNECTION="127.0.0.1 50704 127.0.0.1 22"
no_ss
case_ ss-missing rides unknown

# 9. ss without process information (the carrier belongs to another user) -> assume yes
reset_stubs
export SSH_CONNECTION="127.0.0.1 50705 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50705 127.0.0.1:22'
case_ ss-without-process-info rides unknown

# 10. only the socket of THIS session counts: same client port, another peer
reset_stubs
export SSH_CONNECTION="127.0.0.1 50706 127.0.0.1 22"
ss_says 'ESTAB 0      0      127.0.0.1:50706 127.0.0.1:443 users:(("cloudflared",pid=3909,fd=12))' \
  'ESTAB 0      0      192.168.2.9:50706 10.0.0.1:9999 users:(("cloudflared",pid=3909,fd=13))'
proc 3909 cloudflared /usr/local/bin/cloudflared '0::/init.scope'
case_ other-socket-same-port rides unknown

# 11. no SSH_CONNECTION under an sshd parent (sudo/su strip it) -> undeterminable -> assume yes
reset_stubs
pstat 100 bash 99
pstat 99 sudo 98
pstat 98 sshd-session 97
pstat 97 sshd 1
case_ no-ssh-connection-under-sshd rides unknown

# 12. no SSH_CONNECTION and no sshd anywhere above: a console, CI or a detached multiplexer.
# This is the one "no" the guard gives without seeing a carrier; CI and local consoles rely
# on it, and a tunnel restart cannot disconnect any of them.
reset_stubs
pstat 100 bash 99
pstat 99 tmux:server 1
case_ no-ssh-connection-no-sshd no none

# 13. a malformed SSH_CONNECTION (loopback, no client port) -> undeterminable -> assume yes
reset_stubs
export SSH_CONNECTION="127.0.0.1"
ss_says 'ESTAB 0      0      127.0.0.1:1 127.0.0.1:22 users:(("tailscaled",pid=1,fd=1))'
case_ malformed-ssh-connection rides unknown

if ((fails == 0)); then
  echo "cf-gate-session: $ran case(s) passed"
else
  echo "cf-gate-session: $fails of $ran case(s) failed"
  exit 1
fi
