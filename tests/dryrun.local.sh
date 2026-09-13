# shellcheck shell=bash
# tests/dryrun.local.sh: woow-cf-tunnel invariants on top of the vendored tests/dryrun.sh.
# Sourced at its end; uses $REPO $WORK $VARS, render_variant, and its failures/variants
# counters. Each check renders the units the way scripts/install.sh does, runs the
# podman 4.9.3 generator, and asserts on what the live migration depends on.

# _cf_env_of <envfile> <KEY> [default]: one value, without touching the caller's QL_ENV
_cf_env_of() { (ql_env_load "$1" && ql_env_get "$2" "${@:3}"); }

# cf_check <name> <envfile> <with_auth:0|1>
cf_check() {
  local name=$1 env=$2 auth=$3
  local d=$WORK/cf-$name
  local src=$d/src out=$d/out gen=$d/gen
  mkdir -p "$src" "$out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$src/"
  if ((auth)); then cp -p "$REPO/quadlet/optional/woow-cf-tunnel-auth.container" "$src/"; fi
  variants=$((variants + 1))
  echo "== cf-$name (woow-cf-tunnel invariants, env ${env#"$REPO"/}, auth=$auth)"
  local -a bad=()
  if ! (render_variant "$src" "$env" "$out"); then
    echo "FAIL cf-$name: render"; failures=$((failures + 1)); return 0
  fi
  if ((auth)) && ! ql_render "$REPO/config/auth/auth-nginx.conf" "$env" "$VARS" "$out/config"; then
    echo "FAIL cf-$name: render auth-nginx.conf"; failures=$((failures + 1)); return 0
  fi
  if ! ql_dryrun "$out" --verify --keep "$gen" >/dev/null 2>"$d/dryrun.err"; then
    cat "$d/dryrun.err" >&2
    echo "FAIL cf-$name: dry-run"; failures=$((failures + 1)); return 0
  fi

  local port metrics vol listen ht img es svc=$gen/woow-cf-tunnel.service
  port=$(_cf_env_of "$env" UVICORN_PORT)
  metrics=$(_cf_env_of "$env" CF_METRICS_ADDR)
  vol=$(_cf_env_of "$env" CF_DATA_VOLUME)
  listen=$(_cf_env_of "$env" AUTH_LISTEN)
  ht=$(_cf_env_of "$env" AUTH_HTPASSWD)
  img=$(cf_image_ref)
  es=$(grep '^ExecStart=' "$svc")
  has() { [[ $es == *"$1"* ]] || bad+=("ExecStart lacks: $1"); }
  lacks() { [[ $es != *"$1"* ]] || bad+=("ExecStart must not contain: $1"); }

  has '--network=host'
  has "-v $vol:/data"
  has '--env UVICORN_HOST=127.0.0.1'
  has "--env UVICORN_PORT=$port"
  has "--env CF_METRICS_ADDR=$metrics"
  has '--health-cmd /usr/local/bin/cf-webui-healthcheck'
  has '--health-on-failure kill'
  has '--pull never'
  has '--cap-drop=all'
  has '--security-opt=no-new-privileges'
  has '--stop-timeout=20'
  lacks '--env-file'
  lacks '--publish'
  [[ $es == *" $img uvicorn backend.main:app" ]] || bad+=("ExecStart does not end with '$img uvicorn backend.main:app'")
  grep -qx 'Restart=always' "$svc" || bad+=("Restart=always missing")
  grep -qx 'WantedBy=default.target' "$svc" || bad+=("WantedBy=default.target missing")
  grep -qx 'StartLimitIntervalSec=0' "$svc" || bad+=("StartLimitIntervalSec=0 missing")
  grep -q "^ExecStart=.*podman volume create --ignore .* $vol\$" "$gen/woow-cf-tunnel-data-volume.service" \
    || bad+=("volume unit does not adopt $vol")

  if ((auth)); then
    local asvc=$gen/woow-cf-tunnel-auth.service conf=$out/config/auth-nginx.conf
    grep -qx "AssertFileNotEmpty=$ht" "$asvc" || bad+=("auth unit lacks AssertFileNotEmpty=$ht")
    grep -qx 'AssertFileNotEmpty=%h/.config/woow-cf-tunnel/auth-nginx.conf' "$asvc" || bad+=("auth unit lacks the nginx.conf assertion")
    grep -qE '^(Requires|BindsTo|PartOf)=.*woow-cf-tunnel\.service' "$asvc" && bad+=("auth unit must not be coupled to the tunnel unit")
    grep -q -- "-v $ht:/etc/nginx/htpasswd:ro" "$asvc" || bad+=("auth unit does not mount $ht")
    grep -qx "        listen $listen;" "$conf" || bad+=("auth-nginx.conf does not listen on $listen")
    grep -qx "            proxy_pass http://127.0.0.1:$port;" "$conf" || bad+=("auth-nginx.conf does not proxy to :$port")
  else
    [[ ! -e $gen/woow-cf-tunnel-auth.service ]] || bad+=("auth unit rendered without --with-auth")
  fi

  if ((${#bad[@]})); then
    printf '  FAIL %s\n' "${bad[@]}" >&2
    echo "FAIL cf-$name"; failures=$((failures + 1))
  else
    echo "ok   cf-$name"
  fi
}

# cf_refuse <description> <KEY=VALUE for the env file | WOOW_CF_IMAGE=ref>: render_args must fail
cf_refuse() {
  local desc=$1 kv=$2 f=$WORK/refuse-$variants.env
  variants=$((variants + 1))
  if [[ ${kv%%=*} == WOOW_CF_IMAGE ]]; then
    cp "$EXAMPLE_ENV" "$f"
    if (export WOOW_CF_IMAGE=${kv#*=}; ql_env_load "$f"; render_args "$f") 2>/dev/null; then
      echo "FAIL refuse: $desc"; failures=$((failures + 1)); return 0
    fi
  else
    grep -v "^${kv%%=*}=" "$EXAMPLE_ENV" >"$f"
    printf '%s\n' "$kv" >>"$f"
    if (ql_env_load "$f"; render_args "$f") 2>/dev/null; then
      echo "FAIL refuse: $desc"; failures=$((failures + 1)); return 0
    fi
  fi
  echo "ok   refuse: $desc"
}

cf_check example "$EXAMPLE_ENV" 0
cf_check example-auth "$EXAMPLE_ENV" 1
cf_check compose-volume "$REPO/tests/fixtures/compose-volume.env" 0
cf_check custom-ports-auth "$REPO/tests/fixtures/custom-ports.env" 1

cf_refuse "metrics on 0.0.0.0" CF_METRICS_ADDR=0.0.0.0:20241
cf_refuse "privileged GUI port" UVICORN_PORT=80
cf_refuse "GUI and metrics on one port" CF_METRICS_ADDR=127.0.0.1:18000
cf_refuse "auth proxy on the GUI port" AUTH_LISTEN=127.0.0.1:18000
cf_refuse "volume name with a slash" CF_DATA_VOLUME=../cf_data
cf_refuse "floating image tag" WOOW_CF_IMAGE=localhost/woow-cf-tunnel:latest
cf_refuse "foreign image" WOOW_CF_IMAGE=docker.io/cloudflare/cloudflared:2026.6.1
