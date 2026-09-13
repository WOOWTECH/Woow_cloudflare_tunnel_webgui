#!/usr/bin/env bash
# tests/lock-release.sh: a script that ends normally must give the per-app lock back.
#
# Vendored by Woow_quadlet_migration_plan/lib/sync-lib.sh; do not edit here. It needs nothing
# from the repo but scripts/lib/quadlet-lib.sh and scripts/*.sh: no container, no unit, no
# network. Everything runs under a temporary HOME.
#
# What it guards, and why it exists
# ---------------------------------
# Until quadlet-lib 1.4.0 the lock was a file descriptor and died with the process, so it did
# not matter that install.sh and migrate-legacy.sh ran
#
#     ql_lock "$APP"
#     WORK=$(mktemp -d ...)
#     trap 'rm -rf "$WORK"' EXIT          # <- replaces the handler ql_lock armed
#
# Since 1.5.0 the lock is the directory <state>/<app>/lock.d with an owner record, so that
# bare trap leaves it behind: the run exits cleanly and the NEXT run announces
#
#     taking over the lock left behind by pid N, which is no longer running
#
# It blocks nothing - the takeover path works - but it makes every ordinary run look like
# crash recovery, which teaches operators to ignore the one message that means something.
# quadlet-lib 1.6.0 adds ql_cleanup for exactly this tidy-up; it runs inside the release
# handler instead of replacing it.
#
#   behaviour   drives this repo's own vendored library, so CI proves the copy this repo
#               ships releases the lock and that a second clean run reports no takeover
#   shape       scripts/*.sh must use ql_cleanup, never a bare trap after taking the lock,
#               and must not carry a private "the lock is already held" flag of their own
#
# Every test runs in its own subshell on purpose (isolated HOME, state root, environment), so
# the "modified in a subshell" notes do not apply here:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LIB=$REPO/scripts/lib/quadlet-lib.sh
[[ -f $LIB ]] || { echo "lock-release: missing $LIB" >&2; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lock-release.XXXXXX")
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in: $1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2]"; }

run() {
  local t=$1 log rc
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state"
    export HOME=$T/home TMPDIR=$T QL_STATE_ROOT=$T/state QL_LOG_PREFIX=t T LIB
    unset QL_LOCK_HELD WOOW_LOCK_HELD WOOW_QL_LOCK_HELD CF_LOCK_HELD HA_LOCK_FD QL_APP
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1)); printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1)); FAILED+=("$t"); printf 'FAIL  %s\n' "$t"
    sed 's/^/      | /' "$log"
  fi
}

# ---- fixture: a stand-alone script that locks the way a repo script does -------------------
# MODE=trap   the shape this test forbids: tidy up with a bare EXIT trap after locking
# MODE=hook   the shape the scripts use now: tidy up with ql_cleanup
# MODE=plain  lock and return
mk_fixture() {
  cat >"$T/locker.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$LIB"
ql_lock app
WORK=$(mktemp -d "$TMPDIR/work.XXXXXX")
printf '%s' "$WORK" >"$T/work.path"
case ${MODE:-plain} in
  trap) trap 'rm -rf "$WORK"' EXIT ;;
  hook) ql_cleanup work rm -rf "$WORK" ;;
  plain) ;;
  hold) printf '%s' "$$" >"$T/holder.pid"; while :; do sleep 0.2; done ;;
  *) exit 64 ;;
esac
EOS
  chmod +x "$T/locker.sh"
}
OUT=''
locker() { OUT=''; env "$@" bash "$T/locker.sh" >"$T/run.out" 2>&1; local rc=$?; OUT=$(<"$T/run.out"); return $rc; }
LOCKD() { printf '%s' "$QL_STATE_ROOT/app/lock.d"; }
await_lock() {
  local i=0
  while ((i++ < 200)); do [[ -f $(LOCKD)/owner ]] && return 0; sleep 0.05; done
  die_t "the holder never took the lock"
}

# ======================================================================================
# behaviour: this repo's vendored quadlet-lib
# ======================================================================================
t_a_bare_exit_trap_after_the_lock_is_what_this_test_forbids() {
  # Not a bug in the library and not fixable there: bash REPLACES an EXIT handler, it does
  # not chain. Pinned here so the shape rule below has its reason attached to the symptom.
  mk_fixture
  locker MODE=trap || die_t "MODE=trap failed: $OUT"
  [[ -d $(LOCKD) ]] || die_t "a bare EXIT trap after ql_lock is supposed to lose the release"
  locker MODE=plain || die_t "the second run failed: $OUT"
  has "$OUT" "taking over the lock left behind" "the second CLEAN run is announced as crash recovery"
}

t_ql_cleanup_tidies_up_and_the_next_run_reports_no_takeover() {
  mk_fixture
  locker MODE=hook || die_t "MODE=hook failed: $OUT"
  [[ ! -e $(<"$T/work.path") ]] || die_t "the ql_cleanup hook did not remove the work directory"
  [[ ! -d $(LOCKD) ]] || die_t "a ql_cleanup hook must not cost the lock its release"
  locker MODE=plain || die_t "the second run failed: $OUT"
  hasnt "$OUT" "taking over the lock left behind" "a clean exit must not look like a crash to the next run"
}

t_a_stale_lock_held_value_cannot_produce_an_unlocked_run() {
  # The local wrappers this repo used to carry (app_lock/WOOW_LOCK_HELD, WOOW_QL_LOCK_HELD,
  # CF_LOCK_HELD) skipped ql_lock on a bare string compare, so a value a crashed parent left
  # in the environment made the next run lock nothing at all. ql_lock reads only
  # QL_LOCK_HELD, and only when that pid is still alive AND still owns the lock directory.
  mk_fixture
  local dead
  dead=$(bash -c 'echo $$') # a pid that has certainly exited
  locker MODE=plain WOOW_LOCK_HELD=app WOOW_QL_LOCK_HELD=app CF_LOCK_HELD=1 \
    QL_LOCK_HELD="app|$(sed -n 1p /proc/sys/kernel/random/boot_id)|$dead|1|$(LOCKD)" \
    || die_t "a stale flag must not stop a run: $OUT"
  hasnt "$OUT" "keeping the lock held by the calling script" "a dead owner is not a caller"
  [[ ! -d $(LOCKD) ]] || die_t "the run did not release the lock it took"

  # and with a real, live holder the run is refused rather than let through
  env MODE=hold bash "$T/locker.sh" >"$T/hold.out" 2>&1 &
  local bg=$!
  await_lock
  if locker MODE=plain WOOW_LOCK_HELD=app WOOW_QL_LOCK_HELD=app CF_LOCK_HELD=1; then
    kill "$bg" 2>/dev/null
    die_t "a stale flag let a second run in while pid $bg really held the lock"
  fi
  has "$OUT" "another install/upgrade/uninstall of app is running"
  kill "$bg" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true
}

# ======================================================================================
# shape: what scripts/*.sh are allowed to do
# ======================================================================================
# scripts_taking_a_lock: the scripts that take the lock, one path per line. The retired local
# wrappers are matched too, so the rule below cannot be dodged by wrapping ql_lock again.
scripts_taking_a_lock() {
  grep -lE '(^|[^[:alnum:]_])(ql_lock|app_lock|ha_lock)([^[:alnum:]_]|$)' "$REPO"/scripts/*.sh 2>/dev/null || true
}

t_no_script_installs_a_trap_after_taking_the_lock() {
  # awk over each script that locks: once ql_lock has been called, a bare
  # `trap ... EXIT|INT|TERM|HUP` throws the release handler away. Tidy-up goes to ql_cleanup.
  #
  # Line order is execution order only within one scope, so top-level code and each function
  # body are tracked apart (house style: `name() {` opens one, `}` in column 1 closes it).
  # A handler a function installs BEFORE it locks is fine - that is what ql_lock chains onto -
  # and cf-gate's watchdog does exactly that.
  local f hits='' out
  while read -r f; do
    [[ -n $f ]] || continue
    out=$(awk '
      /^[[:space:]]*#/ { next }
      /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { infn = 1; fnlocked = 0; next }
      infn && /^\}/ { infn = 0; next }
      /(^|[^[:alnum:]_])(ql_lock|app_lock|ha_lock)([^[:alnum:]_]|$)/ {
        if (infn) fnlocked = 1; else toplocked = 1
      }
      /^[[:space:]]*trap[[:space:]]/ && /(EXIT|INT|TERM|HUP)/ && (infn ? fnlocked : toplocked) {
        printf "%s:%d: %s\n", FILENAME, NR, $0
      }' "$f")
    [[ -z $out ]] || hits+=$out$'\n'
  done < <(scripts_taking_a_lock)
  [[ -z $hits ]] || die_t "tidy-up after ql_lock must use ql_cleanup, not a bare trap:"$'\n'"$hits"
}

t_no_script_carries_its_own_lock_held_flag() {
  # app_lock/WOOW_LOCK_HELD, WOOW_QL_LOCK_HELD, CF_LOCK_HELD, ha_lock/HA_LOCK_FD: local
  # wrappers that decided "the lock is already held" from a plain environment variable, with
  # no check that the process that set it still exists. ql_lock owns that decision now.
  local hits
  hits=$(grep -rnE '\b(app_lock|ha_lock|WOOW_LOCK_HELD|WOOW_QL_LOCK_HELD|CF_LOCK_HELD|HA_LOCK_FD)\b' \
    "$REPO"/scripts --include='*.sh' 2>/dev/null | grep -v '/lib/quadlet-lib\.sh:' || true)
  [[ -z $hits ]] || die_t "a private lock-held flag is weaker than ql_lock (no liveness check):"$'\n'"$hits"
}

# ======================================================================================
echo "lock-release against quadlet-lib $(sed -n 's/^QL_LIB_VERSION="\(.*\)"$/\1/p' "$LIB")"
for t in $(declare -F | awk '{print $3}' | grep '^t_'); do run "$t"; done
rm -rf "$ROOT"
echo "----"
echo "passed: $npass  failed: $nfail"
((nfail == 0)) || { echo "failed: ${FAILED[*]}"; exit 1; }
