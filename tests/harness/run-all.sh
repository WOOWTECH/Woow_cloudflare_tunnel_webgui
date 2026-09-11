#!/usr/bin/env bash
# tests/harness/run-all.sh: control-flow tests for install.sh, migrate-legacy.sh and
# upgrade.sh against mocked podman / systemctl / curl / ss / loginctl / systemd-run.
# Needs bash, git, python3, the podman 4.9.3 Quadlet generator and systemd-analyze
# (apt install podman); creates no containers and touches nothing outside a temp dir.
#
#   tests/harness/run-all.sh [filter]     run the cases whose name matches the filter
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export HARNESS_TMP
HARNESS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-harness.XXXXXX")
trap 'rm -rf "$HARNESS_TMP"' EXIT
# shellcheck source=common.sh
. "$HERE/common.sh"
# shellcheck source=cases-install.sh
. "$HERE/cases-install.sh"
filter=${1:-}
fails=0 ran=0
snapshot_repo

run_case() {
  local name=$1 out rc=0
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  out=$( (A_FAILS=0; "$name") 2>&1) || rc=$?
  if ((rc == 0)); then
    echo "ok    ${name#case_}"
  else
    echo "FAIL  ${name#case_}"
    printf '%s\n' "$out" | tail -n 30 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

for c in "${INSTALL_CASES[@]}"; do run_case "$c"; done

# expect <kind> <scenario> <mode> <regex>...: run the scenario once; every regex must match
expect() {
  local kind=$1 sc=$2 mode=$3 name="$1/$2/$3" out re bad=''
  shift 3
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  out=$(SOAKS=${SOAKS:-4} bash "$HERE/scenario.sh" "$kind" "$sc" "$mode" 2>&1)
  for re in "$@"; do grep -qE "$re" <<<"$out" || bad+="
      wanted /$re/"; done
  if [[ -z $bad ]]; then
    echo "ok    $name"
  else
    echo "FAIL  $name$bad"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

# the legacy -> Quadlet swap: commits
expect migrate happy direct 'phase=committed'
expect migrate happy swap 'phase=committed'
expect migrate openclaw direct 'phase=committed' 'auth_active=1' 'new_active=1'
# automatic rollbacks
expect migrate never_ready direct 'ROLLED_BACK \(gate timeout.*readyConnections=0' \
  'legacy_active=1 legacy_enabled=1 new_active=0 auth_active=0 quadlet_files=\[\] legacy_unit_file=kept'
expect migrate version_changed direct 'ROLLED_BACK \(gate timeout.*config version 29 != baseline 28'
expect migrate public_mismatch direct 'ROLLED_BACK \(gate timeout.*public hostnames differ'
expect migrate unhealthy direct 'ROLLED_BACK \(gate timeout.*podman health'
expect migrate happy sigterm 'ROLLED_BACK \(watchdog exited unexpectedly'
expect migrate happy soak_restart 'ROLLED_BACK \(woow-cf-tunnel.service restarted during soak'
SOAKS=10 expect migrate happy soak_lost 'ROLLED_BACK \(tunnel not ready for 3'
expect migrate never_ready abort 'ROLLED_BACK \(operator abort'
expect migrate happy postcommit_rollback 'ROLLED_BACK \(manual rollback'
# refusals that change nothing
expect migrate legacy_unhealthy direct 'ABORTED_BEFORE_CHANGE'
expect migrate broken_config direct 'preflight refused' 'cannot read the ingress config version'
expect migrate tunnel_session direct 'arrives through cloudflared'

# upgrade of an installed woow-cf-tunnel
expect upgrade happy direct 'phase=committed' 'images: running=new installed=new'
expect upgrade happy swap 'phase=committed'
expect upgrade bad_image direct 'ROLLED_BACK \(gate timeout' 'images: running=old installed=old' 'new_active=1'
expect upgrade noop direct 'no upgrade run started' 'already up to date'

if ((fails == 0)); then echo "harness: $ran case(s) passed"; else echo "harness: $fails of $ran case(s) failed"; exit 1; fi
