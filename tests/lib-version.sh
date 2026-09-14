#!/usr/bin/env bash
# tests/lib-version.sh: the vendored quadlet-lib really is the version it declares.
#
# Vendored by Woow_quadlet_migration_plan/lib/sync-lib.sh; do not edit here. It reads two
# files and nothing else: scripts/lib/quadlet-lib.sh and scripts/lib/quadlet-lib.versions.
#
# Why this exists
# ---------------
# scripts/lib/quadlet-lib.manifest is written by the repo itself at sync time, so
# `sha256sum -c` on it proves only "nobody edited this file after it was copied here". It
# cannot say WHICH quadlet-lib was copied. In September 2026 two different files were both
# released as 1.7.0 - the canonical one grew ql_require_healthcheck_timers,
# ql_stop_healthcheck_timer and an active ql_wait_container_healthy after this repo had
# vendored its copy - and every gate in the fleet stayed green, because each one only ever
# compared a copy with itself. The dry-run banner, the CHANGELOG and every version-keyed
# assertion said 1.7.0 and meant two different things.
#
# quadlet-lib.versions is the canonical ledger: one line per released (version, sha256) pair.
# This check asks the ledger what the declared version's content is supposed to be, so a copy
# that claims a version it is not fails here.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LIB=$REPO/scripts/lib/quadlet-lib.sh
LEDGER=$REPO/scripts/lib/quadlet-lib.versions

die() { printf 'lib-version: ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f $LIB ]] || die "missing $LIB"
[[ -f $LEDGER ]] || die "missing $LEDGER (re-run Woow_quadlet_migration_plan/lib/sync-lib.sh)"

version=$(sed -n 's/^QL_LIB_VERSION="\(.*\)"$/\1/p' "$LIB" | head -n1)
[[ -n $version ]] || die "$LIB declares no QL_LIB_VERSION"
hash=$(sha256sum "$LIB" | cut -d' ' -f1)
status=$(awk -v v="$version" -v h="$hash" '
  /^[[:space:]]*(#|$)/ { next }
  $1 == v { seen = 1; if ($2 == h) { print $3; found = 1; exit } }
  END { if (!found) print (seen ? "collision" : "unknown") }
' "$LEDGER")

case $status in
  released) printf 'lib-version: quadlet-lib %s (%s) is the released %s\n' "$version" "${hash:0:12}" "$version" ;;
  withdrawn) die "quadlet-lib.sh declares $version, which the ledger marks WITHDRAWN: that number was published with more than one content. Re-vendor with lib/sync-lib.sh." ;;
  collision) die "quadlet-lib.sh declares $version but ${hash:0:12} is NOT the content released as $version - the version string does not identify this file. Re-vendor with lib/sync-lib.sh." ;;
  unknown) die "quadlet-lib.sh declares $version, which is not in the ledger at all. Re-vendor with lib/sync-lib.sh." ;;
  *) die "unreadable ledger status '$status'" ;;
esac
