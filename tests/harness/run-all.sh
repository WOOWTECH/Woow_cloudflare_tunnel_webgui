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

if ((fails == 0)); then echo "harness: $ran case(s) passed"; else echo "harness: $fails of $ran case(s) failed"; exit 1; fi
