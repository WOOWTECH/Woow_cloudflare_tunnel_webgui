#!/usr/bin/env bash
# tests/dryrun.sh: render the units the way scripts/install.sh does, then check them against
# the podman 4.9.3 Quadlet generator and systemd-analyze. Creates no containers; runs in CI
# (ubuntu-24.04, apt podman 4.9.3) and locally.
#
# Vendored by Woow_quadlet_migration_plan/lib/sync-lib.sh; do not edit here. Put repo-specific
# variants and assertions in tests/dryrun.local.sh (sourced at the end; it can call
# run_variant NAME ENVFILE FILE... and read $WORK, $APP, $REPO).
#
# Variants (each: ql_render -> ql_lint_policy -> ql_dryrun --verify):
#   example            quadlet/* + systemd/*            with config/<app>.env.example
#   example+optional   ... + quadlet/optional/*         (only when that dir exists)
#   fixture-<name>     quadlet/* + systemd/*            with each tests/fixtures/<name>.env
# Units owned by other apps (cross-app Network=/Volume= references) go in tests/fixtures/refs/.
# Computed values: if scripts/render-args.sh exists it is sourced and render_args <envfile>
# fills RENDER_ARGS=(KEY=VALUE...) exactly as scripts/install.sh does.
# APP defaults to the single config/*.env.example basename.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
export QL_LOG_PREFIX=dryrun

shopt -s nullglob
APP=${APP:-}
if [[ -z $APP ]]; then
  examples=("$REPO"/config/*.env.example)
  ((${#examples[@]} == 1)) || ql_die "set APP=<name>: expected exactly one config/*.env.example, found ${#examples[@]}"
  APP=$(basename "${examples[0]}" .env.example)
fi
EXAMPLE_ENV=$REPO/config/$APP.env.example
[[ -f $EXAMPLE_ENV ]] || ql_die "missing $EXAMPLE_ENV"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dryrun-$APP.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
VARS=$REPO/quadlet/render-vars
if [[ ! -f $VARS ]]; then
  VARS=$WORK/render-vars.empty
  : >"$VARS"
fi
REFARGS=()
[[ -d $REPO/tests/fixtures/refs ]] && REFARGS=(--ref-dir "$REPO/tests/fixtures/refs")
if [[ -f $REPO/scripts/render-args.sh ]]; then
  # shellcheck source=/dev/null
  . "$REPO/scripts/render-args.sh"
fi
export QL_ENV_MODE_CHECK=0

# render_variant <stage> <envfile> <out>: what install.sh does (runs in a subshell: ql_die exits)
render_variant() {
  local -a RENDER_ARGS=()
  ql_env_load "$2"
  if declare -F render_args >/dev/null; then render_args "$2"; fi
  ql_render "$1" "$2" "$VARS" "$3" "${RENDER_ARGS[@]}"
}
failures=0 variants=0

# run_variant <name> <envfile> <file...>: stage the files flat, render, lint, dry-run.
run_variant() {
  local name=$1 env=$2
  shift 2
  local stage=$WORK/$name/src out=$WORK/$name/out
  mkdir -p "$stage" "$out"
  cp -p -- "$@" "$stage/"
  variants=$((variants + 1))
  echo "== $name ($# files, env ${env#"$REPO"/})"
  # ql_render exits on unresolved tokens: run it in a subshell so later variants still run.
  if (render_variant "$stage" "$env" "$out") && ql_lint_policy "$out" && ql_dryrun "$out" --verify "${REFARGS[@]}"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failures=$((failures + 1))
  fi
}

base=()
for f in "$REPO"/quadlet/*; do
  [[ -f $f ]] || continue
  case $f in *.container | *.volume | *.network | *.kube | *.image | *.pod | *.build) base+=("$f") ;; esac
done
for f in "$REPO"/systemd/*; do
  [[ -f $f ]] || continue
  case $f in *.service | *.timer | *.target | *.socket | *.path | *.slice) base+=("$f") ;; esac
done
((${#base[@]})) || ql_die "no units under $REPO/quadlet or $REPO/systemd"

run_variant example "$EXAMPLE_ENV" "${base[@]}"
optional=("$REPO"/quadlet/optional/*)
((${#optional[@]} == 0)) || run_variant example+optional "$EXAMPLE_ENV" "${base[@]}" "${optional[@]}"
for fx in "$REPO"/tests/fixtures/*.env; do
  run_variant "fixture-$(basename "$fx" .env)" "$fx" "${base[@]}"
done

if [[ -f $REPO/tests/dryrun.local.sh ]]; then
  # shellcheck source=/dev/null
  . "$REPO/tests/dryrun.local.sh"
fi

echo "$variants variant(s), $failures failed (quadlet-lib $QL_LIB_VERSION, $("$(_ql_quadlet_bin)" -version 2>/dev/null || echo 'quadlet ?'))"
((failures == 0 && variants > 0))
