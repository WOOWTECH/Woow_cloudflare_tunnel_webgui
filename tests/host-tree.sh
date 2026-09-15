#!/usr/bin/env bash
# tests/host-tree.sh: pins the probes that make preflight tell the truth about a host whose
# cf-tunnel deployment is not the shape this package assumes (scripts/lib/cf-gate.sh).
#
# woowtechopenclaw is that host:
#   - its unit is `podman-cf-tunnel-webgui.service`, not `cf-tunnel-webgui.service`
#   - its GUI is `uvicorn --host 0.0.0.0 --port 8888`, not the repo's 18000 on loopback
#   - its woow-tailscale-gateway serves TCP 18081/443/8443/9443/9444 and NOT :22, so setting
#     RESCUE_CONTAINER to it used to turn the rescue-path check green while the host had no
#     second way in at all - and the swap it green-lights carries the only SSH path
#
# No tunnel, no tailnet, no user manager: everything runs against stubs.
#
#   tests/host-tree.sh [filter]
#
# Every case runs in its own subshell (own HOME, own PATH), so:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cf-host-tree.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
filter=${1:-}
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }

case_() {
  local name=$1
  shift
  if [[ -n $filter && $name != *"$filter"* ]]; then return 0; fi
  local out
  if out=$( ("$@") 2>&1); then
    npass=$((npass + 1))
    printf 'ok   %s\n' "$name"
  else
    nfail=$((nfail + 1))
    FAILED+=("$name")
    printf 'FAIL %s\n%s\n' "$name" "$out"
  fi
}

load() {
  # shellcheck source=../scripts/lib/quadlet-lib.sh
  . "$REPO/scripts/lib/quadlet-lib.sh"
  # shellcheck source=../scripts/lib/cf-gate.sh
  . "$REPO/scripts/lib/cf-gate.sh"
}

mk_home() {
  local h
  h=$(mktemp -d "$ROOT/home.XXXXXX")
  mkdir -p "$h/.config/systemd/user"
  printf '%s' "$h"
}

# The shape `tailscale serve status --json` returns. Ports are openclaw's, read read-only on
# 2026-09-13: TCP forwards for 18081, 443, 8443, 9443, 9444 - and no :22.
SERVE_OPENCLAW='{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true},"9443":{"HTTPS":true},
"9444":{"HTTPS":true},"18081":{"HTTPS":true}},"Web":{},"AllowFunnel":{}}'
SERVE_WITH_SSH='{"TCP":{"22":{"TCPForward":"127.0.0.1:22"},"443":{"HTTPS":true}},"Web":{}}'
# `tailscale debug prefs`, trimmed to the field that decides whether inbound is accepted at all.
PREFS_SHIELDS_OFF='{"ShieldsUp":false,"RunSSH":false,"NoStatefulFiltering":true}'
PREFS_SHIELDS_ON='{"ShieldsUp":true,"RunSSH":false,"NoStatefulFiltering":true}'

# mk_podman <home> <serve json> [cmd tokens] [createcommand tokens]: a podman stub answering
# `exec <c> sh -c ...` with the serve JSON and `inspect -f ...` with the uvicorn command line.
# The stub must tell `tailscale serve status` apart from `tailscale debug prefs`: cf_rescue_ssh_ok
# asks the same container both questions and a stub that answers everything with the serve JSON
# makes the prefs branch untestable. `ss` is stubbed for the same reason - without it the test
# would read the REAL workstation's :22 and pass or fail by accident.
mk_podman() {
  local h=$1 serve=$2 cmd=${3-} create=${4-} prefs=${5-} sshd=${6-} bin=$1/bin
  mkdir -p "$bin"
  printf '%s' "$serve" >"$h/serve.json"
  printf '%s' "$cmd" >"$h/cmd.txt"
  printf '%s' "$create" >"$h/create.txt"
  printf '%s' "$prefs" >"$h/prefs.json"
  printf '%s' "$sshd" >"$h/sshd.txt"
  {
    printf '#!/usr/bin/env bash\nD=%q\n' "$h"
    cat <<'STUB'
case ${1:-} in
  exec)
    want=$*
    if [[ $want == *"debug prefs"* ]]; then
      [[ -s $D/prefs.json ]] || exit 1; cat "$D/prefs.json"
    else
      [[ -s $D/serve.json ]] || exit 1; cat "$D/serve.json"
    fi ;;
  inspect)
    fmt=''
    for a in "$@"; do [[ $a == *'{{'* ]] && fmt=$a; done
    case $fmt in
      *CreateCommand*) tr ' ' '\n' <"$D/create.txt" ;;
      *Config.Cmd*) tr ' ' '\n' <"$D/cmd.txt" ;;
    esac ;;
esac
exit 0
STUB
  } >"$bin/podman"
  chmod +x "$bin/podman"
  {
    printf '#!/usr/bin/env bash\nD=%q\n' "$h"
    cat <<'STUB'
# `ss -lntH 'sport = :22'` -> one line in ss's real column layout, or nothing.
[[ -s $D/sshd.txt ]] || exit 0
printf 'LISTEN 0 4096 %s 0.0.0.0:*\n' "$(cat "$D/sshd.txt")"
STUB
  } >"$bin/ss"
  chmod +x "$bin/ss"
  printf '%s' "$bin"
}

# ---- cf_json_tcp_ports --------------------------------------------------------------------
t_tcp_ports_openclaw() {
  load
  local out
  out=$(printf '%s' "$SERVE_OPENCLAW" | cf_json_tcp_ports)
  eq "$out" "443
8443
9443
9444
18081" "the served TCP ports, numerically sorted"
  hasnt "$out" "22" "there is no :22 on this host"
}

t_tcp_ports_with_ssh() {
  load
  local out
  out=$(printf '%s' "$SERVE_WITH_SSH" | cf_json_tcp_ports)
  eq "$out" "22
443" "a host that does serve :22"
}

t_tcp_ports_garbage() {
  load
  local out rc=0
  out=$(printf 'not json' | cf_json_tcp_ports 2>/dev/null) || rc=$?
  eq "$rc" 1 "non-JSON input must fail, not report an empty port list as success"
  eq "$out" "" "no output"
}

# ---- cf_rescue_ssh_ok ---------------------------------------------------------------------
# The single highest-risk item in this area: RESCUE_CONTAINER=woow-tailscale-gateway passed the
# old "is it running" check and green-lit the swap that carries the host's only SSH path.
t_rescue_refuses_gateway_without_ssh() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW")
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok woow-tailscale-gateway) || rc=$?
  eq "$rc" 1 "a rescue container that does not serve :22 must not pass"
  has "$out" ":22 is not served" "the diagnosis"
  has "$out" "18081" "the ports it does serve are printed"
  has "$out" "RESCUE_PROOF=lan" "the deliberate override is offered"
}

t_rescue_accepts_real_ssh() {
  HOME=$(mk_home)
  export HOME
  local bin
  bin=$(mk_podman "$HOME" "$SERVE_WITH_SSH")
  PATH=$bin:$PATH
  export PATH
  load
  cf_rescue_ssh_ok woow-tailscale || die_t "a container that serves :22 must pass"
}

# The openclaw shape: no :22 serve rule, ShieldsUp off, sshd on 0.0.0.0:22. This is a REAL way in
# - it is the path every 2026-09-15 reading of that host was taken over - and the old check called
# it "not a way back in", which would have pushed the operator to RESCUE_PROOF=lan on a host where
# the tailnet path was fine all along.
t_rescue_accepts_userspace_forward() {
  HOME=$(mk_home)
  export HOME
  local bin out
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" '' '' "$PREFS_SHIELDS_OFF" '0.0.0.0:22')
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok woow-tailscale-gateway) || die_t "ShieldsUp off + a listening sshd is a way in, with or without a serve rule"
  has "$out" "none is needed" "it says why no rule is required"
  has "$out" "0.0.0.0:22" "it names the listener it found"
  has "$out" "does not prove the tailnet ACL" "it is honest that this is evidence, not proof"
}

# ShieldsUp ON drops every inbound connection, so the fallback genuinely does not exist.
t_rescue_refuses_shields_up() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" '' '' "$PREFS_SHIELDS_ON" '0.0.0.0:22')
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok woow-tailscale-gateway) || rc=$?
  eq "$rc" 1 "ShieldsUp on is not a rescue path"
  has "$out" "ShieldsUp is ON" "the reason is named"
}

# ShieldsUp off proves nothing if no sshd is listening for the node to hand the connection to.
t_rescue_refuses_no_sshd() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" '' '' "$PREFS_SHIELDS_OFF" '')
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok woow-tailscale-gateway) || rc=$?
  eq "$rc" 1 "no sshd means no way in, whatever the node does"
  has "$out" "listening on :22" "the reason is named"
}

# Unreadable prefs must not be read as "off". Absence of evidence is not evidence.
t_rescue_refuses_unreadable_prefs() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" '' '' '' '0.0.0.0:22')
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok woow-tailscale-gateway) || rc=$?
  eq "$rc" 1 "prefs that cannot be read are not a demonstrated path"
  has "$out" "could not read ShieldsUp" "the reason is named"
}

t_rescue_refuses_unreadable() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" "")
  PATH=$bin:$PATH
  export PATH
  load
  out=$(cf_rescue_ssh_ok some-container) || rc=$?
  eq "$rc" 1 "an unreadable serve status is not a demonstrated rescue path"
  has "$out" "not a demonstrated rescue path" "the diagnosis"
}

# ---- cf_units_mentioning ------------------------------------------------------------------
t_units_mentioning() {
  HOME=$(mk_home)
  export HOME
  printf 'ExecStart=/usr/bin/podman start cf-tunnel-webgui\nExecStop=/usr/bin/podman stop cf-tunnel-webgui\n' \
    >"$HOME/.config/systemd/user/podman-cf-tunnel-webgui.service"
  printf 'ExecStart=/usr/bin/podman start something-else\n' \
    >"$HOME/.config/systemd/user/other.service"
  load
  eq "$(cf_units_mentioning cf-tunnel-webgui)" "podman-cf-tunnel-webgui.service" \
    "the unit that really runs the container"
}

# ---- the uvicorn command line -------------------------------------------------------------
t_uvicorn_parse_spaced() {
  load
  eq "$(printf '%s\n' uvicorn backend.main:app --host 0.0.0.0 --port 8888 | cf_uvicorn_args_parse)" \
    "0.0.0.0|8888" "openclaw's command line"
}

t_uvicorn_parse_equals() {
  load
  eq "$(printf '%s\n' uvicorn --host=127.0.0.1 --port=18000 | cf_uvicorn_args_parse)" \
    "127.0.0.1|18000" "the --opt=value spelling"
}

t_uvicorn_parse_absent() {
  load
  eq "$(printf '%s\n' /entrypoint.sh | cf_uvicorn_args_parse)" "|" "nothing found"
}

t_legacy_uvicorn_from_cmd() {
  HOME=$(mk_home)
  export HOME
  local bin
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" "uvicorn backend.main:app --host 0.0.0.0 --port 8888" "")
  PATH=$bin:$PATH
  export PATH
  load
  eq "$(cf_legacy_uvicorn cf-tunnel-webgui)" "0.0.0.0|8888" "read from .Config.Cmd"
}

t_legacy_uvicorn_from_createcommand() {
  HOME=$(mk_home)
  export HOME
  local bin
  bin=$(mk_podman "$HOME" "$SERVE_OPENCLAW" "" "podman run --name cf-tunnel-webgui img uvicorn --host 0.0.0.0 --port 8888")
  PATH=$bin:$PATH
  export PATH
  load
  eq "$(cf_legacy_uvicorn cf-tunnel-webgui)" "0.0.0.0|8888" "falls back to .Config.CreateCommand"
}

# ---- the staged unit really does hard-code a loopback bind --------------------------------
# The refusal in cmd_preflight only matters while this is true of quadlet/.
t_staged_unit_hardcodes_loopback() {
  local u=$REPO/quadlet/woow-cf-tunnel.container
  has "$(cat "$u")" "Environment=UVICORN_HOST=127.0.0.1" "the hard-coded loopback bind"
}

# ---- lineage ------------------------------------------------------------------------------
t_lineage_accepts_this_repo() {
  load
  ql_require_own_lineage "$REPO" WOOWTECH/Woow_cloudflare_tunnel_webgui \
    || die_t "this checkout must pass its own lineage check"
}

t_script_run_from_host_tree() {
  HOME=$(mk_home)
  export HOME
  local tree=$HOME/Woow_cloudflare_tunnel_webgui out rc=0
  mkdir -p "$tree/scripts/lib"
  printf '0123456789abcdef\n' >"$tree/.deployed-commit"
  printf '#!/usr/bin/env bash\necho deploy\n' >"$tree/scripts/deploy.sh"
  cp "$REPO/scripts/migrate-legacy.sh" "$tree/scripts/migrate-legacy.sh"
  out=$( (bash "$tree/scripts/migrate-legacy.sh" status) 2>&1) || rc=$?
  eq "$rc" 1 "migrate-legacy.sh must refuse to run out of the host tree"
  hasnt "$out" "No such file or directory" "the bare ENOENT must be gone"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
  has "$out" "do not delete that tree" "the do-not-delete warning"
}

case_ tcp-ports-openclaw t_tcp_ports_openclaw
case_ tcp-ports-with-ssh t_tcp_ports_with_ssh
case_ tcp-ports-garbage t_tcp_ports_garbage
case_ rescue-refuses-gateway-without-ssh t_rescue_refuses_gateway_without_ssh
case_ rescue-accepts-userspace-forward   t_rescue_accepts_userspace_forward
case_ rescue-refuses-shields-up          t_rescue_refuses_shields_up
case_ rescue-refuses-no-sshd             t_rescue_refuses_no_sshd
case_ rescue-refuses-unreadable-prefs    t_rescue_refuses_unreadable_prefs
case_ rescue-accepts-real-ssh t_rescue_accepts_real_ssh
case_ rescue-refuses-unreadable t_rescue_refuses_unreadable
case_ units-mentioning t_units_mentioning
case_ uvicorn-parse-spaced t_uvicorn_parse_spaced
case_ uvicorn-parse-equals t_uvicorn_parse_equals
case_ uvicorn-parse-absent t_uvicorn_parse_absent
case_ legacy-uvicorn-from-cmd t_legacy_uvicorn_from_cmd
case_ legacy-uvicorn-from-createcommand t_legacy_uvicorn_from_createcommand
case_ staged-unit-hardcodes-loopback t_staged_unit_hardcodes_loopback
case_ lineage-accepts-this-repo t_lineage_accepts_this_repo
case_ script-run-from-host-tree t_script_run_from_host_tree

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
