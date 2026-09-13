# shellcheck shell=bash
# quadlet-lib.sh: shared helpers for WOOWTECH podman Quadlet install/upgrade/uninstall scripts.
#
# Canonical copy: Woow_quadlet_migration_plan/lib/quadlet-lib.sh. Every repo vendors it
# unmodified at scripts/lib/quadlet-lib.sh (sync-lib.sh). Do not edit a vendored copy:
# CI checks it against scripts/lib/quadlet-lib.manifest.
#
# Target: Ubuntu 24.04, podman 4.9.3 rootless, systemd 255 user units, linger.
# Source it from bash (4.4+); it is safe under `set -euo pipefail` and does not rely on it.
# Log lines go to stderr. stdout carries only data: changed-file lists, backup paths,
# ql_env_get values, and ql_render output to "-".
#
# Knobs (environment, all optional):
#   QL_APP              app name used for secret labels and "is this file ours" checks
#   QL_QUADLET_BIN      Quadlet generator            (/usr/libexec/podman/quadlet)
#   QL_QUADLET_DIR      installed Quadlet files      (~/.config/containers/systemd)
#   QL_SYSTEMD_USER_DIR plain user units             (~/.config/systemd/user)
#   QL_CONFIG_ROOT      <out>/config/* goes to $QL_CONFIG_ROOT/<app>/   (~/.config)
#   QL_STATE_ROOT       manifests, pending restarts  (~/.local/state/woow-quadlet)
#   QL_HOLD_UNITS       space-separated units ql_apply_units never restarts (only starts)
#   QL_DRY_RUN=1        install/apply/remove/uninstall/secret/pull report instead of acting
#   QL_POLL_INTERVAL    seconds between wait polls   (2)
#   QL_ENV_MODE_CHECK=0 ql_env_load skips the 0600/owner warning (repo example files in CI)
#   QL_PATH_MOUNT_ALLOW containers (space/comma separated) allowed to hold a mount that
#                       CONTAINS a guarded path, e.g. pi-web's %h:/host%h (ql_check_path_mounted)
#   QL_LOG_PREFIX       log prefix                   (basename of $0)

# shellcheck disable=SC2034 # public: read by sync-lib.sh, repo scripts and CI
QL_LIB_VERSION="1.3.0"

# ---------------------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------------------
ql_info() { printf '%s: %s\n' "${QL_LOG_PREFIX:-${0##*/}}" "$*" >&2; }
ql_warn() { printf '%s: WARNING: %s\n' "${QL_LOG_PREFIX:-${0##*/}}" "$*" >&2; }
ql_die()  { printf '%s: ERROR: %s\n' "${QL_LOG_PREFIX:-${0##*/}}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# internal helpers
# ---------------------------------------------------------------------------------------
_ql_quadlet_bin()  { printf '%s' "${QL_QUADLET_BIN:-/usr/libexec/podman/quadlet}"; }
_ql_quadlet_dir()  { printf '%s' "${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}"; }
_ql_sd_user_dir()  { printf '%s' "${QL_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"; }
_ql_config_root()  { printf '%s' "${QL_CONFIG_ROOT:-$HOME/.config}"; }
_ql_state_root()   { printf '%s' "${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}"; }
_ql_state_dir()    { printf '%s/%s' "$(_ql_state_root)" "$1"; }
_ql_manifest()     { printf '%s/manifest' "$(_ql_state_dir "$1")"; }
_ql_pending()      { printf '%s/pending-restart' "$(_ql_state_dir "$1")"; }
_ql_dry()          { [[ ${QL_DRY_RUN:-0} == 1 ]]; }
_ql_sc()           { systemctl --user "$@"; }
_ql_sc_show()      { systemctl --user show -p "$2" --value "$1" 2>/dev/null; }

_ql_valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
_ql_valid_var()  { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
_ql_need_app()   { _ql_valid_name "${1:-}" || ql_die "invalid app name '${1:-}' (want [A-Za-z0-9][A-Za-z0-9_.-]*)"; }

# _ql_in_words <word> <space-separated list>
_ql_in_words() {
  local w
  for w in $2; do [[ $w == "$1" ]] && return 0; done
  return 1
}

# _ql_version_ge <have> <want>: dotted numeric compare; suffixes like -dev/-rc1 are ignored.
_ql_version_ge() {
  local IFS=. i
  local -a q_a q_b
  read -ra q_a <<<"${1%%[-+~]*}"
  read -ra q_b <<<"${2%%[-+~]*}"
  for ((i = 0; i < ${#q_a[@]} || i < ${#q_b[@]}; i++)); do
    local x=${q_a[i]:-0} y=${q_b[i]:-0}
    x=${x//[!0-9]/} y=${y//[!0-9]/}
    x=$((10#${x:-0})) y=$((10#${y:-0}))
    ((x > y)) && return 0
    ((x < y)) && return 1
  done
  return 0
}

# _ql_kind <basename> -> quadlet | unit | unsupported | other
_ql_kind() {
  case $1 in
    *.container | *.volume | *.network | *.kube | *.image) echo quadlet ;;
    *.pod | *.build) echo unsupported ;;
    *.service | *.timer | *.target | *.socket | *.path | *.slice) echo unit ;;
    *) echo other ;;
  esac
}

# _ql_unit_for <basename> -> the systemd unit a source file produces ("" if none)
_ql_unit_for() {
  case $1 in
    *.container) printf '%s.service' "${1%.container}" ;;
    *.kube) printf '%s.service' "${1%.kube}" ;;
    *.volume) printf '%s-volume.service' "${1%.volume}" ;;
    *.network) printf '%s-network.service' "${1%.network}" ;;
    *.image) printf '%s-image.service' "${1%.image}" ;;
    *.service | *.timer | *.target | *.socket | *.path | *.slice) printf '%s' "$1" ;;
  esac
}

# ql_unit_for <file>: the unit a Quadlet/plain unit file produces (x.container -> x.service,
# x.volume -> x-volume.service, x.network -> x-network.service, x.timer -> x.timer); "" otherwise
ql_unit_for() { _ql_unit_for "${1##*/}"; }

# _ql_key_value <file> <section> <key>: last value of Key= inside [section] ("" if none)
_ql_key_value() {
  awk -v want_sec="$2" -v want_key="$3" '
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[.*\][ \t]*$/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s; next }
    sec == want_sec {
      line = $0; sub(/^[ \t]+/, "", line)
      k = line; sub(/[ \t]*=.*$/, "", k)
      if (k == want_key && index(line, "=")) { v = line; sub(/^[^=]*=[ \t]*/, "", v); val = v }
    }
    END { printf "%s", val }' "$1"
}

# _ql_sha <file>
_ql_sha() { local s; s=$(sha256sum -- "$1") || return 1; printf '%s' "${s%% *}"; }

# _ql_manifest_read <app> <assoc-name>: fills assoc[abs-path]=sha256
_ql_manifest_read() {
  local -n __ql_mf_dst=$2
  local f sha path
  __ql_mf_dst=()
  f=$(_ql_manifest "$1")
  [[ -f $f ]] || return 0
  while read -r sha path; do
    [[ -n $sha && -n $path ]] && __ql_mf_dst["$path"]=$sha
  done <"$f"
  return 0
}

# _ql_manifest_write <app> <assoc-name>: atomic, sha256sum -c compatible
_ql_manifest_write() {
  local -n __ql_mw_src=$2
  local f dir tmp p
  f=$(_ql_manifest "$1")
  dir=${f%/*}
  mkdir -p "$dir" || ql_die "cannot create $dir"
  chmod 700 "$dir" || ql_die "cannot chmod $dir"
  tmp=$(mktemp "$dir/.manifest.XXXXXX") || ql_die "cannot write in $dir"
  {
    for p in "${!__ql_mw_src[@]}"; do printf '%s  %s\n' "${__ql_mw_src[$p]}" "$p"; done | LC_ALL=C sort -k2
  } >"$tmp" || ql_die "cannot write $tmp"
  mv -f "$tmp" "$f" || ql_die "cannot replace $f"
}

# _ql_owner_of <abs-path> <our-app>: prints the other app whose manifest lists the path
_ql_owner_of() {
  local root mf app
  root=$(_ql_state_root)
  for mf in "$root"/*/manifest; do
    [[ -f $mf ]] || continue
    app=${mf%/manifest}
    app=${app##*/}
    [[ $app == "$2" ]] && continue
    if awk -v p="$1" '{ sub(/^[^ ]+  /, "") } $0 == p { found = 1 } END { exit !found }' "$mf"; then
      printf '%s' "$app"
      return 0
    fi
  done
  return 1
}

# _ql_set_load <file> <assoc-name> / _ql_set_save <file> <assoc-name>: line sets
_ql_set_load() {
  local -n __ql_sl_dst=$2
  local l
  __ql_sl_dst=()
  [[ -f $1 ]] || return 0
  while IFS= read -r l || [[ -n $l ]]; do [[ -n $l ]] && __ql_sl_dst["$l"]=1; done <"$1"
  return 0
}
_ql_set_save() {
  local -n __ql_ss_src=$2
  local dir=${1%/*} tmp k
  if ((${#__ql_ss_src[@]} == 0)); then rm -f "$1"; return 0; fi
  mkdir -p "$dir" || ql_die "cannot create $dir"
  tmp=$(mktemp "$dir/.set.XXXXXX") || ql_die "cannot write in $dir"
  for k in "${!__ql_ss_src[@]}"; do printf '%s\n' "$k"; done | LC_ALL=C sort >"$tmp" || ql_die "cannot write $tmp"
  mv -f "$tmp" "$1" || ql_die "cannot replace $1"
}

# _ql_backup_copy <app> <file> <reason>: keep a copy of a file we are about to replace/remove
_ql_backup_copy() {
  local dir
  dir="$(_ql_state_dir "$1")/replaced/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir" || ql_die "cannot create $dir"
  cp -p -- "$2" "$dir/${2##*/}" || ql_die "cannot back up $2"
  ql_warn "$3: $2 (copy kept in $dir/)"
}

# ---------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------
ql_require_rootless() {
  [[ $(id -u) != 0 ]] || ql_die "run this as the normal user that owns the containers, not as root or via sudo (rootless podman + systemd --user)"
  [[ -n ${XDG_RUNTIME_DIR:-} ]] || ql_warn "XDG_RUNTIME_DIR is not set; systemctl --user will fail (log in via ssh/console, or: export XDG_RUNTIME_DIR=/run/user/$(id -u))"
  return 0
}

# ql_require_podman_min <version>, e.g. ql_require_podman_min 4.9
ql_require_podman_min() {
  local want=${1:?usage: ql_require_podman_min <version>} out have
  command -v podman >/dev/null 2>&1 || ql_die "podman not found (sudo apt-get install podman)"
  out=$(podman --version 2>/dev/null) || ql_die "podman --version failed"
  [[ $out =~ ([0-9]+(\.[0-9]+)+) ]] || ql_die "cannot parse podman version from: $out"
  have=${BASH_REMATCH[1]}
  _ql_version_ge "$have" "$want" || ql_die "podman $have is too old; need >= $want"
  ql_info "podman $have (>= $want)"
}

ql_require_quadlet() {
  local bin g found=''
  bin=$(_ql_quadlet_bin)
  [[ -x $bin ]] || ql_die "Quadlet generator $bin not found (podman >= 4.4 package)"
  for g in ${QL_USER_GENERATOR:-/usr/lib/systemd/user-generators/podman-user-generator /lib/systemd/user-generators/podman-user-generator /etc/systemd/user-generators/podman-user-generator}; do
    [[ -e $g ]] && { found=$g; break; }
  done
  [[ -n $found ]] || ql_die "podman-user-generator is not installed in systemd's user-generators dir: daemon-reload would never generate the Quadlet units"
  return 0
}

ql_require_user_systemd() {
  command -v systemctl >/dev/null 2>&1 || ql_die "systemctl not found"
  _ql_sc show-environment >/dev/null 2>&1 \
    || ql_die "no systemd user manager reachable. Log in as this user over ssh/console (not su/sudo -u), or run: export XDG_RUNTIME_DIR=/run/user/$(id -u)"
  local fs
  fs=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)
  [[ $fs == cgroup2fs ]] || ql_warn "cgroup v2 not detected (/sys/fs/cgroup is '${fs:-?}'); rootless resource limits and --cgroups=split may fail"
  return 0
}

# ql_preflight <min-podman-version>: rootless + podman version + quadlet + user systemd
ql_preflight() {
  ql_require_rootless
  ql_require_podman_min "${1:-4.9}"
  ql_require_quadlet
  ql_require_user_systemd
}

# ql_enable_linger: idempotent. Dies (after printing the sudo command) if polkit refuses,
# unless QL_ALLOW_NO_LINGER=1.
ql_enable_linger() {
  local user=${USER:-} state
  [[ -n $user ]] || user=$(id -un)
  local flag="${QL_LINGER_DIR:-/var/lib/systemd/linger}/$user"
  state=$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)
  if [[ -e $flag || $state == yes ]]; then ql_info "linger already enabled for $user"; return 0; fi
  if _ql_dry; then ql_info "[dry-run] would run: loginctl enable-linger $user"; return 0; fi
  if loginctl enable-linger --no-ask-password "$user" >/dev/null 2>&1; then
    state=$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)
    if [[ -e $flag || $state == yes ]]; then ql_info "enabled linger for $user"; return 0; fi
  fi
  ql_warn "could not enable linger for $user (polkit requires an administrator). Run once:"
  printf '    sudo loginctl enable-linger %s\n' "$user" >&2
  [[ ${QL_ALLOW_NO_LINGER:-0} == 1 ]] && { ql_warn "continuing without linger: units stop when $user logs out"; return 0; }
  ql_die "linger is required so the units survive logout and start at boot"
}

# ql_enable_podman_socket: for units that mount %t/podman/podman.sock. Never disabled by uninstall.
ql_enable_podman_socket() {
  if [[ $(_ql_sc is-enabled podman.socket 2>/dev/null || true) == enabled ]] && _ql_sc is-active --quiet podman.socket; then
    return 0
  fi
  if _ql_dry; then ql_info "[dry-run] would run: systemctl --user enable --now podman.socket"; return 0; fi
  _ql_sc enable --now podman.socket || ql_die "systemctl --user enable --now podman.socket failed"
  ql_info "enabled podman.socket"
}

# ql_lock <app>: exclusive per-app lock for the rest of the calling script (flock).
ql_lock() {
  _ql_need_app "${1:-}"
  local dir fd
  dir=$(_ql_state_dir "$1")
  mkdir -p "$dir" || ql_die "cannot create $dir"
  exec {fd}>"$dir/lock" || ql_die "cannot open $dir/lock"
  flock -n "$fd" || ql_die "another install/upgrade/uninstall of $1 is running (lock $dir/lock)"
  # shellcheck disable=SC2034 # public: the fd holding the lock
  QL_LOCK_FD=$fd
}

# ---------------------------------------------------------------------------------------
# env files: KEY=VALUE data, never sourced
# ---------------------------------------------------------------------------------------
unset QL_ENV QL_ENV_KEYS
declare -gA QL_ENV=()
# shellcheck disable=SC2034 # public: filled by ql_env_load (file order)
declare -ga QL_ENV_KEYS=()
QL_ENV_FILE=''
QL_ENV_CREATED=0

# _ql_env_parse <file> <assoc-name> [<keys-array-name>]: returns 1 after printing all errors
_ql_env_parse() {
  local __ql_f=$1 __ql_line __ql_n=0 __ql_k __ql_v
  local -n __ql_ep_dst=$2
  local -a __ql_errs=() __ql_order=()
  __ql_ep_dst=()
  [[ -f $__ql_f && -r $__ql_f ]] || { ql_warn "env file not found or not readable: $__ql_f"; return 1; }
  while IFS= read -r __ql_line || [[ -n $__ql_line ]]; do
    __ql_n=$((__ql_n + 1))
    if [[ $__ql_line == *$'\r'* ]]; then
      __ql_errs+=("$__ql_f:$__ql_n: CRLF line ending (fix with: sed -i 's/\\r\$//' $__ql_f)")
      continue
    fi
    [[ $__ql_line =~ ^[[:space:]]*$ || $__ql_line =~ ^[[:space:]]*# ]] && continue
    if [[ $__ql_line =~ ^export[[:space:]] ]]; then
      __ql_errs+=("$__ql_f:$__ql_n: 'export' is not allowed (plain KEY=VALUE only)")
      continue
    fi
    if [[ ! $__ql_line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      __ql_errs+=("$__ql_f:$__ql_n: not a KEY=VALUE line (no spaces around '=', no leading blanks)")
      continue
    fi
    __ql_k=${BASH_REMATCH[1]} __ql_v=${BASH_REMATCH[2]}
    if [[ $__ql_v =~ [[:space:]]# ]]; then
      __ql_errs+=("$__ql_f:$__ql_n: inline '# comment' after the value of $__ql_k (podman --env-file keeps it as part of the value)")
      continue
    fi
    if [[ $__ql_v =~ [[:space:]]$ ]]; then
      __ql_errs+=("$__ql_f:$__ql_n: trailing whitespace in the value of $__ql_k")
      continue
    fi
    if [[ $__ql_v =~ ^\"(.*)\"$ || $__ql_v =~ ^\'(.*)\'$ ]]; then
      ql_warn "$__ql_f:$__ql_n: $__ql_k is quoted; quotes are kept literally (podman does not strip them)"
    fi
    if [[ -n ${__ql_ep_dst[$__ql_k]+x} ]]; then
      ql_warn "$__ql_f:$__ql_n: $__ql_k is set more than once; the last value wins"
    else
      __ql_order+=("$__ql_k")
    fi
    __ql_ep_dst["$__ql_k"]=$__ql_v
  done <"$__ql_f"
  if ((${#__ql_errs[@]})); then
    printf '  %s\n' "${__ql_errs[@]}" >&2
    return 1
  fi
  if [[ -n ${3:-} ]]; then
    local -n __ql_ep_keys=$3
    __ql_ep_keys=("${__ql_order[@]}")
  fi
  return 0
}

# ql_env_load <envfile>: fills QL_ENV[KEY]=VALUE and QL_ENV_KEYS (file order). No eval,
# no expansion. Rejects CRLF, inline comments, export, trailing blanks. Dies on errors.
ql_env_load() {
  local f=${1:?usage: ql_env_load <envfile>} xt=0 rc=0 mode
  [[ $- == *x* ]] && xt=1 && set +x # values may be secrets: never trace them
  _ql_env_parse "$f" QL_ENV QL_ENV_KEYS || rc=$?
  ((xt)) && set -x
  ((rc == 0)) || ql_die "invalid env file $f (see above)"
  QL_ENV_FILE=$f
  if [[ ${QL_ENV_MODE_CHECK:-1} == 1 ]]; then
    mode=$(stat -c %a -- "$f" 2>/dev/null || true)
    [[ $mode =~ 00$ ]] || ql_warn "$f is mode $mode; it should be 0600 (chmod 600 $f)"
    [[ -O $f ]] || ql_warn "$f is not owned by $(id -un)"
  fi
  return 0
}

# ql_env_get <KEY> [default]: prints the loaded value; without a default a missing key fails.
ql_env_get() {
  local k=${1:?usage: ql_env_get <KEY> [default]}
  if [[ -n ${QL_ENV[$k]+x} ]]; then printf '%s' "${QL_ENV[$k]}"; return 0; fi
  if (($# >= 2)); then printf '%s' "$2"; return 0; fi
  ql_warn "$k is not set in ${QL_ENV_FILE:-the env file}"
  return 1
}

# ql_env_ensure <example> <envfile>: create envfile (0600, dir 0700) from the example when
# missing (sets QL_ENV_CREATED=1); otherwise fix its mode and warn about keys the example
# has that the file lacks (new settings after an upgrade).
ql_env_ensure() {
  local ex=${1:?usage: ql_env_ensure <example> <envfile>} f=${2:?usage: ql_env_ensure <example> <envfile>}
  local dir=${f%/*} k
  local -a q_missing=()
  [[ -f $ex ]] || ql_die "example env file not found: $ex"
  QL_ENV_CREATED=0
  if [[ ! -e $f ]]; then
    if _ql_dry; then ql_info "[dry-run] would create $f from $ex"; return 0; fi
    if [[ ! -d $dir ]]; then
      mkdir -p "$dir" || ql_die "cannot create $dir"
      chmod 700 "$dir" || ql_die "cannot chmod $dir"
    fi
    install -m 600 -- "$ex" "$f" || ql_die "cannot create $f"
    # shellcheck disable=SC2034 # public: install.sh stops for review on first run
    QL_ENV_CREATED=1
    ql_info "created $f from ${ex##*/}; review it before continuing"
    return 0
  fi
  [[ -O $f ]] || ql_die "$f is not owned by $(id -un)"
  if [[ $(stat -c %a -- "$f") != 600 ]]; then
    chmod 600 -- "$f" || ql_die "cannot chmod 600 $f"
    ql_warn "set $f to mode 0600"
  fi
  local -A cur_keys=() ex_keys=()
  _ql_env_parse "$f" cur_keys >/dev/null 2>&1 || true
  _ql_env_parse "$ex" ex_keys || ql_die "invalid example env file $ex"
  for k in "${!ex_keys[@]}"; do [[ -n ${cur_keys[$k]+x} ]] || q_missing+=("$k"); done
  if ((${#q_missing[@]})); then
    ql_warn "$f lacks keys that ${ex##*/} defines: $(printf '%s\n' "${q_missing[@]}" | LC_ALL=C sort | tr '\n' ' ')(copy them from $ex)"
  fi
  return 0
}

# ql_env_set <envfile> <KEY> <VALUE>: atomic edit (replace first KEY= line, drop duplicates,
# or append), keeps mode 0600, updates QL_ENV when that file is loaded. Never traces values.
ql_env_set() {
  local f=${1:?usage: ql_env_set <envfile> <KEY> <VALUE>} k=${2:?usage: ql_env_set <envfile> <KEY> <VALUE>} v=${3-}
  local xt=0 dir tmp line replaced=0
  _ql_valid_var "$k" || ql_die "ql_env_set: invalid key '$k'"
  [[ $v != *$'\n'* && $v != *$'\r'* ]] || ql_die "ql_env_set: value of $k must be a single line"
  [[ ! $v =~ [[:space:]]# ]] || ql_die "ql_env_set: value of $k contains ' #', which podman would treat as data"
  [[ ! $v =~ [[:space:]]$ ]] || ql_die "ql_env_set: value of $k has trailing whitespace"
  [[ -f $f ]] || ql_die "ql_env_set: $f does not exist"
  if _ql_dry; then ql_info "[dry-run] would set $k in $f"; return 0; fi
  [[ $- == *x* ]] && xt=1 && set +x
  dir=${f%/*}
  tmp=$(umask 077 && mktemp "$dir/.${f##*/}.XXXXXX") || { ((xt)) && set -x; ql_die "cannot write in $dir"; }
  {
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line == "$k="* ]]; then
        ((replaced)) && continue
        printf '%s=%s\n' "$k" "$v"
        replaced=1
      else
        printf '%s\n' "$line"
      fi
    done <"$f"
    ((replaced)) || printf '%s=%s\n' "$k" "$v"
  } >"$tmp"
  chmod 600 "$tmp" && mv -f "$tmp" "$f"
  local rc=$?
  [[ $QL_ENV_FILE == "$f" ]] && QL_ENV[$k]=$v
  ((xt)) && set -x
  ((rc == 0)) || ql_die "cannot update $f"
  return 0
}

# ql_expand_home <value>: %h -> $HOME, for script-side use of values meant for unit files.
ql_expand_home() { printf '%s' "${1//%h/$HOME}"; }

# ql_assert_match <label> <value> <ERE>: die unless the whole value matches.
ql_assert_match() {
  [[ $2 =~ ^($3)$ ]] || ql_die "$1: invalid value '$2' (must match $3)"
}

# ---------------------------------------------------------------------------------------
# rendering (D2): @@VAR@@ tokens, whitelist in quadlet/render-vars
# ---------------------------------------------------------------------------------------
# ql_render <src_dir|file> <envfile|-> <vars_file> <out_dir|-> [KEY=VALUE...]
#   Substitutes @@VAR@@ for VAR listed in <vars_file>. Values come from the KEY=VALUE
#   arguments (computed by the script; may be multi-line) and then from <envfile>.
#   A whitelisted VAR that is set to "" renders as "". Everything else is copied byte
#   for byte (${VAR}, $var, %h stay). Unresolved or malformed tokens are listed, then it
#   dies before writing anything. File modes are preserved. src_dir: its regular,
#   non-hidden top-level files except "render-vars". out "-" prints one rendered file.
ql_render() {
  (($# >= 4)) || ql_die "usage: ql_render <src_dir|file> <envfile|-> <vars_file> <out_dir|-> [KEY=VALUE...]"
  local src=$1 envf=$2 varsf=$3 out=$4
  shift 4
  local xt=0 rc=0
  [[ $- == *x* ]] && xt=1 && set +x
  _ql_render "$src" "$envf" "$varsf" "$out" "$@" || rc=$?
  ((xt)) && set -x
  return "$rc"
}

_ql_render() {
  local src=$1 envf=$2 varsf=$3 out=$4
  shift 4
  local -A q_allow=() q_vals=() q_envv=()
  local -a q_files=() q_bad=() q_rendered=()
  local f line n k v kv i content rest outline tok m had_nl srcdir
  if [[ -d $src ]]; then
    srcdir=$src
    for f in "$src"/*; do
      [[ -f $f ]] || continue
      [[ ${f##*/} == render-vars ]] && continue
      q_files+=("$f")
    done
  elif [[ -f $src ]]; then
    srcdir=$(dirname -- "$src")
    q_files=("$src")
  else
    ql_die "ql_render: source $src does not exist"
  fi
  [[ -f $varsf ]] || ql_die "ql_render: vars file $varsf not found (one variable name per line)"
  n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]]; then
      q_allow[${BASH_REMATCH[1]}]=1
    else
      q_bad+=("$varsf:$n: not a variable name: $line")
    fi
  done <"$varsf"
  local envlabel='the KEY=VALUE arguments'
  if [[ $envf != - ]]; then
    _ql_env_parse "$envf" q_envv || ql_die "ql_render: invalid env file $envf (see above)"
    envlabel="$envf or the KEY=VALUE arguments"
  fi
  for kv in "$@"; do
    [[ $kv == *=* ]] || { q_bad+=("argument '$kv' is not KEY=VALUE"); continue; }
    k=${kv%%=*} v=${kv#*=}
    _ql_valid_var "$k" || { q_bad+=("argument key '$k' is not a variable name"); continue; }
    [[ -n ${q_allow[$k]+x} ]] || { q_bad+=("argument $k is not listed in $varsf"); continue; }
    q_vals[$k]=$v
  done
  for k in "${!q_allow[@]}"; do
    [[ -n ${q_vals[$k]+x} ]] && continue
    [[ -n ${q_envv[$k]+x} ]] && q_vals[$k]=${q_envv[$k]}
  done
  for k in "${!q_vals[@]}"; do
    [[ ${q_vals[$k]} == *@@* ]] && q_bad+=("value of $k contains '@@' (not allowed: it would look like a token)")
    [[ ${q_vals[$k]} == *$'\r'* ]] && q_bad+=("value of $k contains a carriage return")
  done
  if ((${#q_bad[@]})); then
    printf '  %s\n' "${q_bad[@]}" >&2
    ql_die "ql_render: bad render inputs"
  fi

  for i in "${!q_files[@]}"; do
    f=${q_files[$i]} content='' n=0 had_nl=1
    [[ -s $f && -n $(tail -c1 -- "$f") ]] && had_nl=0
    while IFS= read -r line || [[ -n $line ]]; do
      n=$((n + 1)) rest=$line outline=''
      while [[ $rest =~ @@([A-Za-z_][A-Za-z0-9_]*)@@ ]]; do
        tok=${BASH_REMATCH[1]} m=${BASH_REMATCH[0]}
        outline+=${rest%%"$m"*}
        rest=${rest#*"$m"}
        if [[ -z ${q_allow[$tok]+x} ]]; then
          q_bad+=("$f:$n: @@$tok@@ ($tok is not listed in $varsf)")
        elif [[ -z ${q_vals[$tok]+x} ]]; then
          q_bad+=("$f:$n: @@$tok@@ ($tok is not set in $envlabel)")
        else
          outline+=${q_vals[$tok]}
        fi
      done
      outline+=$rest
      if [[ $outline =~ @@[^@[:space:]]+@@ ]]; then
        q_bad+=("$f:$n: malformed token ${BASH_REMATCH[0]} (names are [A-Za-z_][A-Za-z0-9_]*)")
      fi
      content+=$outline$'\n'
    done <"$f"
    ((had_nl)) || content=${content%$'\n'}
    q_rendered[i]=$content
  done
  if ((${#q_bad[@]})); then
    printf '  %s\n' "${q_bad[@]}" >&2
    ql_die "ql_render: ${#q_bad[@]} unresolved token(s); nothing was written"
  fi

  if [[ $out == - ]]; then
    ((${#q_files[@]} == 1)) || ql_die "ql_render: output '-' needs a single source file"
    printf '%s' "${q_rendered[0]}"
    return 0
  fi
  mkdir -p -- "$out" || ql_die "ql_render: cannot create $out"
  [[ $(cd -- "$out" && pwd -P) != "$(cd -- "$srcdir" && pwd -P)" ]] || ql_die "ql_render: output dir must differ from the source dir"
  local tmp dst
  for i in "${!q_files[@]}"; do
    f=${q_files[$i]}
    dst=$out/${f##*/}
    tmp=$(mktemp "$out/.ql-render.XXXXXX") || ql_die "ql_render: cannot write in $out"
    printf '%s' "${q_rendered[i]}" >"$tmp" || ql_die "ql_render: cannot write $tmp"
    chmod "$(stat -c %a -- "$f")" "$tmp" || ql_die "ql_render: cannot chmod $tmp"
    mv -f "$tmp" "$dst" || ql_die "ql_render: cannot write $dst"
  done
  return 0
}

# ---------------------------------------------------------------------------------------
# static checks
# ---------------------------------------------------------------------------------------
_ql_fail() { printf '  FAIL %s\n' "$*" >&2; }

# _ql_refs <file>: Quadlet unit references (x.volume, x.network, x.image) of a .container/.kube
_ql_refs() {
  awk '
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[.*\][ \t]*$/ { next }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      k = line; sub(/[ \t]*=.*$/, "", k)
      if (!index(line, "=")) next
      v = line; sub(/^[^=]*=[ \t]*/, "", v)
      if (k == "Volume" || k == "Network" || k == "Image") {
        n = split(v, parts, /[ \t]+/)
        for (i = 1; i <= n; i++) { r = parts[i]; sub(/:.*/, "", r); if (r ~ /\.(volume|network|image)$/) print r }
      } else if (k == "Mount") {
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) { r = parts[i]; if (r ~ /^(source|src)=/) { sub(/^[^=]*=/, "", r); if (r ~ /\.volume$/) print r } }
      }
    }' "$1"
}

# ql_lint <dir> [--ref-dir DIR]...: podman 4.9.3 traps in a rendered unit set. Prints every
# finding, returns 1 if any. Run by ql_dryrun (install time and CI).
ql_lint() {
  local dir='' fails=0 f b u r d found target
  local -a q_refdirs=()
  while (($#)); do
    case $1 in
      --ref-dir) q_refdirs+=("${2:?--ref-dir needs a directory}"); shift ;;
      -*) ql_die "ql_lint: unknown option $1" ;;
      *) [[ -z $dir ]] || ql_die "ql_lint: one directory only"; dir=$1 ;;
    esac
    shift
  done
  [[ -d $dir ]] || ql_die "ql_lint: $dir is not a directory"
  local -A q_units=()
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    u=$(_ql_unit_for "$b")
    [[ -n $u ]] && q_units[$u]=$b
  done
  for f in "$dir"/*; do
    b=${f##*/}
    if [[ -d $f ]]; then
      case $b in
        *.container.d | *.volume.d | *.network.d | *.kube.d | *.image.d | container.d | volume.d | network.d | kube.d | image.d)
          _ql_fail "$b/: Quadlet drop-in directories are ignored by podman 4.9.3 (render the values into the unit)"
          fails=1 ;;
      esac
      continue
    fi
    [[ -f $f ]] || continue
    if grep -nE '@@[A-Za-z_][A-Za-z0-9_]*@@' -- "$f" >/dev/null; then
      _ql_fail "$b: unrendered @@TOKEN@@ left: $(grep -noE '@@[A-Za-z_][A-Za-z0-9_]*@@' -- "$f" | head -n3 | tr '\n' ' ')"
      fails=1
    fi
    case $(_ql_kind "$b") in
      unsupported) _ql_fail "$b: .pod/.build units do not exist in podman 4.9.3"; fails=1; continue ;;
      quadlet) ;;
      unit)
        if [[ $b == *.timer ]]; then
          target=$(_ql_key_value "$f" Timer Unit)
          [[ -n $target ]] || target=${b%.timer}.service
          [[ -n ${q_units[$target]+x} ]] || { _ql_fail "$b: triggers $target, which is not in this unit set"; fails=1; }
        fi
        continue ;;
      *) continue ;;
    esac
    # Quadlet file
    u=$(_ql_unit_for "$b")
    if [[ -f $dir/$u ]]; then
      _ql_fail "$b: a plain unit $u sits next to it; a file in ~/.config/systemd/user shadows the generated unit"
      fails=1
    fi
    local out
    out=$(awk -v F="$b" '
      /^[ \t]*[#;]/ { next }
      /^[ \t]*\[.*\][ \t]*$/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s; next }
      {
        line = $0; sub(/^[ \t]+/, "", line)
        if (!index(line, "=")) next
        k = line; sub(/[ \t]*=.*$/, "", k)
        v = line; sub(/^[^=]*=[ \t]*/, "", v)
        if (sec == "Container" && k == "EnvironmentFile" && v ~ /^-/) printf "%s:%d: EnvironmentFile=- in [Container] is passed verbatim to --env-file and breaks (drop the -)\n", F, FNR
        if (sec == "Container" && k == "Notify" && v == "healthy") printf "%s:%d: Notify=healthy is silently ignored by podman 4.9.3 (poll readiness in the script)\n", F, FNR
        if (sec == "Container" && k == "StopTimeout") printf "%s:%d: StopTimeout= is not a podman 4.9.3 key; use PodmanArgs=--stop-timeout=N\n", F, FNR
        if (sec == "Container" && k == "PublishPort" && v ~ /\$/) printf "%s:%d: PublishPort= rejects ${VAR} in podman 4.9.3; render the value with @@VAR@@\n", F, FNR
        if (sec == "Volume" && k == "VolumeName" && v != "") vn = 1
        if (sec == "Network" && k == "NetworkName" && v != "") nn = 1
      }
      END {
        if (F ~ /\.volume$/ && !vn) printf "%s: no VolumeName=; Quadlet would name the volume systemd-%s and not adopt existing data\n", F, substr(F, 1, length(F) - 7)
        if (F ~ /\.network$/ && !nn) printf "%s: no NetworkName=; Quadlet would name the network systemd-%s\n", F, substr(F, 1, length(F) - 8)
      }' "$f")
    if [[ -n $out ]]; then
      while IFS= read -r line; do _ql_fail "$line"; done <<<"$out"
      fails=1
    fi
    case $b in
      *.container | *.kube)
        while IFS= read -r r; do
          [[ -z $r || -f $dir/$r ]] && continue
          found=0
          for d in "${q_refdirs[@]}"; do [[ -f $d/$r ]] && { found=1; break; }; done
          ((found)) || { _ql_fail "$b: references $r, which is not in this unit set (it would silently become systemd-${r%.*})"; fails=1; }
        done < <(_ql_refs "$f")
        ;;
    esac
  done
  ((fails == 0))
}

# ql_lint_policy <dir>: WOOWTECH STANDARD rules for repo CI (NOT for install time: per-host
# values may legitimately contain literal paths). Opt out per file with a comment line
#   # ql-lint: allow <rule>     rules: floating-tag no-tag localhost-pull restart wantedby
#                                     success-exit plaintext-secret literal-path
ql_lint_policy() {
  local dir=${1:?usage: ql_lint_policy <dir>} f b fails=0 out
  [[ -d $dir ]] || ql_die "ql_lint_policy: $dir is not a directory"
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    case $(_ql_kind "$b") in quadlet | unit) ;; *) continue ;; esac
    out=$(awk -v F="$b" '
      function allowed(rule) { return (rule in allow) }
      /^[ \t]*#[ \t]*ql-lint:[ \t]*allow[ \t]/ { n = split($0, w, /[ \t]+/); for (i = 1; i <= n; i++) allow[w[i]] = 1; next }
      /^[ \t]*[#;]/ { next }
      /^[ \t]*\[.*\][ \t]*$/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s; next }
      {
        line = $0; sub(/^[ \t]+/, "", line)
        if (!index(line, "=")) next
        k = line; sub(/[ \t]*=.*$/, "", k)
        v = line; sub(/^[^=]*=[ \t]*/, "", v)
        if (sec == "Container" && k == "Image") image = v
        if (sec == "Container" && k == "Pull") pull = v
        if (sec == "Service" && k == "Restart" && v != "no") restart = 1
        if (sec == "Service" && k == "SuccessExitStatus" && v ~ /(^|[ \t])143([ \t]|$)/) success143 = 1
        if (sec == "Install" && k == "WantedBy" && v ~ /(^|[ \t])default\.target([ \t]|$)/) wanted = 1
        if (k == "Environment") {
          n = split(v, kv, /[ \t]+/)
          for (i = 1; i <= n; i++) {
            e = kv[i]; gsub(/"/, "", e); ek = e; sub(/=.*/, "", ek); ev = e; sub(/^[^=]*=?/, "", ev)
            if (ek ~ /(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|MASTER_KEY|SALT_KEY|PRIVATE_KEY)$/ && ev != "" && ev !~ /^\$/) sec_hits = sec_hits sprintf("%s:%d: plaintext credential in Environment=%s (use Secret= or the 0600 EnvironmentFile)\n", F, FNR, ek)
          }
        }
        if ((k == "Environment" || k ~ /^Exec/) && v ~ /:\/\/[^:\/@ ]+:[^@ ]+@/) sec_hits = sec_hits sprintf("%s:%d: credentials embedded in a URL\n", F, FNR)
        host = ""
        if (k == "Volume" || k == "EnvironmentFile") { host = v; sub(/:.*/, "", host) }
        else if (k == "Mount") { host = v }
        else if (k ~ /^Exec/ || k == "WorkingDirectory") { host = v }
        if (host ~ /\/home\/[A-Za-z]|\/run\/user\/[0-9]/) path_hits = path_hits sprintf("%s:%d: literal /home or /run/user path in %s= (use %%h / %%t)\n", F, FNR, k)
      }
      END {
        if (sec_hits != "" && !allowed("plaintext-secret")) printf "%s", sec_hits
        if (path_hits != "" && !allowed("literal-path")) printf "%s", path_hits
        if (F !~ /\.container$/) exit
        if (image == "") { printf "%s: no Image=\n", F; exit }
        if (image !~ /\.image$/ && image !~ /@sha256:/) {
          name = image; tag = ""
          last = name; sub(/.*\//, "", last)
          if (index(last, ":")) { tag = last; sub(/^[^:]*:/, "", tag) }
          if (tag == "" && !allowed("no-tag")) printf "%s: Image=%s has no tag (pin an exact version)\n", F, image
          if (tag ~ /^(latest|stable|main|master|edge|mainline|dev|nightly|beta|rc)$/ && !allowed("floating-tag")) printf "%s: Image=%s uses the floating tag :%s (pin an exact version)\n", F, image, tag
        }
        if (image ~ /^localhost\// && pull != "never" && !allowed("localhost-pull")) printf "%s: localhost/ image needs Pull=never\n", F
        if (!restart && !allowed("restart")) printf "%s: no Restart= in [Service]\n", F
        if (!success143 && !allowed("success-exit")) printf "%s: no SuccessExitStatus=143 in [Service] (podman stops the container with SIGTERM; an entrypoint that does not trap it exits 143 and the unit ends up failed after a clean stop)\n", F
        if (!wanted && !allowed("wantedby")) printf "%s: no WantedBy=default.target in [Install]\n", F
      }' "$f")
    if [[ -n $out ]]; then
      while IFS= read -r line; do _ql_fail "$line"; done <<<"$out"
      fails=1
    fi
  done
  ((fails == 0))
}

# ql_dryrun <dir> [--verify] [--ref-dir DIR]... [--keep DIR]
#   dir: a rendered unit set (Quadlet files plus optional plain helper units, flat).
#   Runs ql_lint, then QUADLET_UNIT_DIRS=<copy> quadlet -dryrun -user. Fails on a non-zero
#   exit, on any stderr line except "Loading source unit file" and the benign
#   "Error occurred resolving path /etc/containers/systemd/users/<uid>", and on any
#   Quadlet file that produced no service. --verify: also systemd-analyze --user verify the
#   generated units together with the plain helper units. --ref-dir: where units owned by
#   other apps live (e.g. ~/.config/containers/systemd) so cross-app references resolve.
#   --keep DIR: copy the generated units there. Returns 1 on failure (does not exit).
ql_dryrun() {
  local dir='' verify=0 keep='' f b u r d fails=0 nsrc=0
  local -a q_refdirs=() q_lintargs=()
  while (($#)); do
    case $1 in
      --verify) verify=1 ;;
      --ref-dir) q_refdirs+=("${2:?--ref-dir needs a directory}"); q_lintargs+=(--ref-dir "$2"); shift ;;
      --keep) keep=${2:?--keep needs a directory}; shift ;;
      -*) ql_die "ql_dryrun: unknown option $1" ;;
      *) [[ -z $dir ]] || ql_die "ql_dryrun: one directory only"; dir=$1 ;;
    esac
    shift
  done
  [[ -d $dir ]] || ql_die "ql_dryrun: $dir is not a directory"
  local bin
  bin=$(_ql_quadlet_bin)
  [[ -x $bin ]] || ql_die "ql_dryrun: Quadlet generator $bin not found"
  ql_lint "$dir" "${q_lintargs[@]}" || fails=1

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/ql-dryrun.XXXXXX") || ql_die "ql_dryrun: mktemp failed"
  mkdir -p "$work/units" "$work/gen"
  local -a q_expected=()
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    [[ $(_ql_kind "$b") == quadlet ]] || continue
    cp -p -- "$f" "$work/units/" || ql_die "ql_dryrun: copy failed"
    q_expected+=("$(_ql_unit_for "$b")")
    nsrc=$((nsrc + 1))
    case $b in
      *.container | *.kube)
        while IFS= read -r r; do
          [[ -z $r || -f $dir/$r || -f $work/units/$r ]] && continue
          for d in "${q_refdirs[@]}"; do [[ -f $d/$r ]] && { cp -p -- "$d/$r" "$work/units/"; break; }; done
        done < <(_ql_refs "$f")
        ;;
    esac
  done
  if ((nsrc == 0)); then
    _ql_fail "no Quadlet files (.container/.volume/.network/.kube/.image) in $dir"
    rm -rf -- "$work"
    return 1
  fi

  local rc=0 badlines
  QUADLET_UNIT_DIRS="$work/units" "$bin" -dryrun -user >"$work/out" 2>"$work/err" || rc=$?
  ((rc == 0)) || { _ql_fail "quadlet -dryrun exited $rc"; fails=1; }
  badlines=$(grep -vE '^(quadlet-generator\[[0-9]+\]: )?(Loading source unit file |Error occurred resolving path "?/etc/containers/systemd/users/[0-9]+"?)|^[[:space:]]*$' "$work/err" || true)
  if [[ -n $badlines ]]; then
    _ql_fail "quadlet -dryrun diagnostics:"
    printf '       %s\n' "$badlines" >&2
    fails=1
  fi
  for u in "${q_expected[@]}"; do
    grep -qxF -- "---$u---" "$work/out" || { _ql_fail "no unit generated for $u"; fails=1; }
  done

  local ngen=0
  if ((verify)); then
    awk -v d="$work/gen" '/^---.*---$/ { if (name) close(d "/" name); name = substr($0, 4, length($0) - 6); next } name { print > (d "/" name) }' "$work/out"
    for f in "$dir"/*; do
      [[ -f $f ]] || continue
      b=${f##*/}
      [[ $(_ql_kind "$b") == unit ]] || continue
      if [[ -e $work/gen/$b ]]; then _ql_fail "$b: plain unit has the same name as a generated one"; fails=1; continue; fi
      cp -p -- "$f" "$work/gen/$b"
    done
    local -a q_vunits=()
    local -A q_names=()
    for f in "$work/gen"/*; do
      [[ -f $f ]] || continue
      q_vunits+=("$f")
      q_names[${f##*/}]=1
    done
    ngen=${#q_vunits[@]}
    if ! command -v systemd-analyze >/dev/null 2>&1; then
      _ql_fail "systemd-analyze not found; cannot --verify"
      fails=1
    elif ((ngen)); then
      # AF_UNIX paths are limited to 108 bytes: a long runtime dir only produces socket noise.
      local rt vrc=0 l hit
      rt=$(mktemp -d /tmp/qlrt.XXXXXX) || ql_die "ql_dryrun: mktemp failed"
      XDG_RUNTIME_DIR=$rt SYSTEMD_UNIT_PATH="$work/gen:" \
        systemd-analyze --user verify --man=no --generators=no "${q_vunits[@]}" >"$work/verify" 2>&1 || vrc=$?
      rm -rf -- "$rt"
      local -a q_relevant=()
      while IFS= read -r l; do
        hit=0
        [[ $l == *"$work/gen/"* ]] && hit=1
        for u in "${!q_names[@]}"; do
          [[ $l == "$u:"* || $l == *"Unit $u "* || $l == *" $u:"* ]] && { hit=1; break; }
        done
        ((hit)) && q_relevant+=("$l")
      done <"$work/verify"
      if ((vrc != 0 || ${#q_relevant[@]})); then
        _ql_fail "systemd-analyze --user verify (rc=$vrc):"
        if ((${#q_relevant[@]})); then
          printf '       %s\n' "${q_relevant[@]//"$work\/gen\/"/}" >&2
        else
          sed 's/^/       /' "$work/verify" >&2
        fi
        fails=1
      fi
    fi
  fi
  if [[ -n $keep ]]; then
    mkdir -p -- "$keep" || ql_die "ql_dryrun: cannot create $keep"
    cp -p -- "$work/out" "$keep/dryrun.out" || ql_die "ql_dryrun: cannot write $keep"
    ((verify)) && cp -pR -- "$work/gen/." "$keep/"
  fi
  rm -rf -- "$work"
  if ((fails)); then
    ql_warn "dry-run FAILED for $dir"
    return 1
  fi
  if ((verify)); then ql_info "dry-run ok: $nsrc Quadlet file(s), $ngen unit(s) verified"; else ql_info "dry-run ok: $nsrc Quadlet file(s)"; fi
  return 0
}

# ---------------------------------------------------------------------------------------
# legacy guards
# ---------------------------------------------------------------------------------------
# ql_check_container_collision <name> <expected_unit>
ql_check_container_collision() {
  local name=${1:?usage: ql_check_container_collision <name> <expected_unit>} expect_unit=${2:?usage: ql_check_container_collision <name> <expected_unit>}
  local rc=0 label d new i=2
  podman container exists "$name" >/dev/null 2>&1 || rc=$?
  ((rc == 1)) && return 0
  ((rc == 0)) || ql_die "podman container exists $name failed (rc=$rc)"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$name" 2>/dev/null) \
    || ql_die "cannot inspect container $name"
  [[ $label == "<no value>" ]] && label=''
  if [[ $label == "$expect_unit" ]]; then
    ql_info "container $name is already managed by $expect_unit"
    return 0
  fi
  d=$(date +%Y%m%d)
  new=$name-legacy-$d
  while podman container exists "$new" >/dev/null 2>&1; do new=$name-legacy-$d-$i; i=$((i + 1)); done
  ql_warn "container '$name' exists but is not managed by $expect_unit (PODMAN_SYSTEMD_UNIT=${label:-<none>})."
  ql_warn "Quadlet starts it with 'podman run --replace', which would DELETE that container."
  ql_warn "Stop and disable whatever runs it (legacy unit / compose), then keep it for rollback with:"
  printf '    podman rename %s %s\n' "$name" "$new" >&2
  ql_die "refusing to continue while '$name' is a legacy container"
}

# ql_check_unit_shadow <unit> [app]: a file (or symlink, or mask) named <unit> in
# ~/.config/systemd/user (or /etc/systemd/user) outranks the Quadlet-generated unit.
# Allowed only when the path is in <app>'s manifest (default $QL_APP).
ql_check_unit_shadow() {
  local unit=${1:?usage: ql_check_unit_shadow <unit> [app]} app=${2:-${QL_APP:-}} d p
  local -a q_dirs=()
  read -ra q_dirs <<<"$(_ql_sd_user_dir) ${QL_SHADOW_DIRS:-/etc/systemd/user}"
  local -A q_mf=()
  [[ -n $app ]] && _ql_manifest_read "$app" q_mf
  for d in "${q_dirs[@]}"; do
    p=$d/$unit
    if [[ -d $p.d ]]; then ql_warn "$p.d/ exists: its drop-ins also apply to the generated $unit"; fi
    [[ -e $p || -L $p ]] || continue
    if [[ -L $p && $(readlink -- "$p") == /dev/null ]]; then
      ql_die "$unit is masked ($p -> /dev/null); run: systemctl --user unmask $unit"
    fi
    [[ -n ${q_mf[$p]+x} ]] && continue
    if [[ $d == "$(_ql_sd_user_dir)" ]]; then
      ql_die "$p exists and is not installed by ${app:-this app}: it shadows the Quadlet-generated $unit. Stop/disable it, then move it away: mv '$p' '$p.legacy-$(date +%Y%m%d)'"
    fi
    ql_die "$p (system-wide) shadows the Quadlet-generated $unit; an administrator must remove it"
  done
  return 0
}

# ql_check_path_mounted [--allow-broader NAME]... <host_path> [allowed_container...]
#   What another running container does with <host_path> is not one relationship but three:
#     it mounts the SAME path                       two writers on our data   -> ql_die
#     it mounts a path INSIDE <host_path>           two writers on our data   -> ql_die
#     <host_path> is INSIDE a broader mount it holds   usually by design      -> ql_warn
#   The third case is normal and must not block an install: a host-file-access container
#   (pi-web's `Volume=%h:/host%h:rw`, which gives the coding agent the home directory)
#   holds a mount that contains EVERY path under $HOME. The warning names the container
#   and the broader mount so an operator can see what holds it.
#   [allowed_container...] are this app's own containers; they are ignored completely.
#   --allow-broader NAME (repeatable) and QL_PATH_MOUNT_ALLOW (names separated by spaces
#   or commas, e.g. QL_PATH_MOUNT_ALLOW=pi-web) declare a known file-access container and
#   silence the warning for it. They cover the third case only: that same container
#   mounting <host_path> itself, or a path inside it, still dies.
#   A failed `podman inspect` warns; it never turns the guard into a silent pass.
ql_check_path_mounted() {
  local q_allow=${QL_PATH_MOUNT_ALLOW:-}
  q_allow=${q_allow//,/ }
  while [[ ${1:-} == --* ]]; do
    case $1 in
      --allow-broader) q_allow+=" ${2:?--allow-broader needs a container name}"; shift ;;
      *) ql_die "ql_check_path_mounted: unknown option $1" ;;
    esac
    shift
  done
  local path=${1:?usage: ql_check_path_mounted [--allow-broader NAME]... <host_path> [allowed_container...]}
  shift
  local real ids name src rows rc=0 a skip
  local -a q_hits=() q_broader=()
  real=$(realpath -m -- "$(ql_expand_home "$path")")
  ids=$(podman ps -q 2>/dev/null) || ql_die "podman ps failed"
  [[ -n $ids ]] || return 0
  local -a q_idarr=()
  read -ra q_idarr <<<"${ids//$'\n'/ }"
  # podman wraps --format in an implicit {{range .}}, so inside the template "." is one
  # container but "$" is the whole inspect array: {{$.Name}} cannot reach the container and
  # makes podman print nothing at all. Capture the container in $c first. Errors are read
  # too (a container may stop between `ps -q` and here) so a broken template cannot turn
  # this guard into a silent pass.
  rows=$(podman inspect --format '{{$c := .}}{{range .Mounts}}{{$c.Name}}|{{.Source}}{{println}}{{end}}' "${q_idarr[@]}" 2>&1) || rc=$?
  ((rc == 0)) || ql_warn "podman inspect exited $rc while checking what bind-mounts $real (a container may have stopped); this guard judged only the rows it did return"
  while IFS='|' read -r name src; do
    [[ -n $name && -n $src ]] || continue
    skip=0
    for a in "$@"; do [[ $a == "$name" ]] && skip=1; done
    ((skip)) && continue
    if [[ $src == "$real" || $src == "$real"/* ]]; then
      # the same path, or one inside it: that container writes our data
      q_hits+=("$name ($src)")
    elif [[ $real == "$src"/* ]]; then
      # our path merely sits inside a broader mount that container holds
      _ql_in_words "$name" "$q_allow" || q_broader+=("$name ($src)")
    fi
  done <<<"$rows"
  ((${#q_hits[@]} == 0)) || ql_die "$real is in use by running container(s): ${q_hits[*]}"
  ((${#q_broader[@]} == 0)) || ql_warn "$real sits inside a broader mount held by running container(s): ${q_broader[*]}; that is normal for a host-file-access container. Declare it (QL_PATH_MOUNT_ALLOW=<name>, or --allow-broader <name>) to silence this."
  return 0
}
# ---------------------------------------------------------------------------------------
# images
# ---------------------------------------------------------------------------------------
# ql_pull_images <rendered_dir>: pull every Image= of the .container files before any unit
# is touched (a pull must not run inside TimeoutStartSec). localhost/ images and Pull=never
# must already exist.
ql_pull_images() {
  local dir=${1:?usage: ql_pull_images <rendered_dir>} f img pull
  for f in "$dir"/*.container; do
    [[ -f $f ]] || continue
    img=$(_ql_key_value "$f" Container Image)
    pull=$(_ql_key_value "$f" Container Pull)
    [[ -z $img || $img == *.image ]] && continue
    if podman image exists "$img" >/dev/null 2>&1; then continue; fi
    if [[ $img == localhost/* || $pull == never ]]; then
      ql_die "${f##*/}: image $img is not present locally and cannot be pulled (build it first)"
    fi
    if _ql_dry; then ql_info "[dry-run] would pull $img"; continue; fi
    ql_info "pulling $img"
    podman pull "$img" >/dev/null || ql_die "podman pull $img failed; nothing was changed"
  done
  return 0
}

# ---------------------------------------------------------------------------------------
# install / apply / remove
# ---------------------------------------------------------------------------------------
# Paths a dry run said it would adopt (ql_adopt_file): ql_install_files treats them as gone,
# the way the real run's move would have left them. Always empty outside a dry run.
_QL_ADOPTED=()

# ql_adopt_file <app> <path>
#   Take over a file this package installed before it kept a manifest (an earlier install.sh
#   that copied a helper unit straight into ~/.config/systemd/user). The file is moved into
#   <state>/<app>/adopted/<timestamp>/, so ql_install_files writes our copy instead of
#   refusing it as a foreign unit. The caller decides what is safe to adopt (same
#   Documentation= URL, ...); this only moves it and keeps the old copy.
#   Under QL_DRY_RUN=1 nothing is moved and the path is remembered instead, so a later
#   ql_install_files in the same dry run reports the write the real run would do rather than
#   dying on a collision the real run never reaches.
ql_adopt_file() {
  local app=${1:?usage: ql_adopt_file <app> <path>} p=${2:?usage: ql_adopt_file <app> <path>} dir
  _ql_need_app "$app"
  [[ -f $p && ! -L $p ]] || ql_die "ql_adopt_file: $p is not a regular file"
  dir="$(_ql_state_dir "$app")/adopted"
  if _ql_dry; then
    _QL_ADOPTED+=("$p")
    ql_info "[dry-run] would adopt $p (moved under $dir/)"
    return 0
  fi
  dir=$dir/$(date +%Y%m%d-%H%M%S)
  mkdir -p "$dir" || ql_die "cannot create $dir"
  mv -- "$p" "$dir/${p##*/}" || ql_die "cannot move $p into $dir/"
  ql_info "adopted $p (old copy: $dir/${p##*/})"
}

# ql_install_files <out_dir> <app> [--prune]
#   Routes rendered files: Quadlet files -> QL_QUADLET_DIR, plain units -> QL_SYSTEMD_USER_DIR,
#   <out_dir>/config/** -> QL_CONFIG_ROOT/<app>/**. Writes only files whose bytes differ
#   (atomic, mode preserved), records sha256s in <state>/<app>/manifest, adds the affected
#   units to <state>/<app>/pending-restart (a changed .volume/.network/.image also marks the
#   containers that reference it), and prints the changed files (one per line, stdout).
#   Refuses a destination owned by another app, and a plain unit in ~/.config/systemd/user
#   that no manifest owns (a legacy hand-written unit). A foreign Quadlet file with our name
#   is adopted after a backup copy. Files installed earlier but absent now are kept (warned)
#   unless --prune, which calls ql_remove_files on them.
ql_install_files() {
  local out=${1:?usage: ql_install_files <out_dir> <app> [--prune]} app=${2:?usage: ql_install_files <out_dir> <app> [--prune]} prune=0
  case ${3:-} in '') ;; --prune) prune=1 ;; *) ql_die "ql_install_files: unknown option $3" ;; esac
  _ql_need_app "$app"
  [[ -d $out ]] || ql_die "ql_install_files: $out is not a directory"
  local qdir sdir cdir f b rel dst kind owner sha
  qdir=$(_ql_quadlet_dir) sdir=$(_ql_sd_user_dir) cdir="$(_ql_config_root)/$app"
  local -a q_srcs=() q_dsts=() q_errs=()
  for f in "$out"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    kind=$(_ql_kind "$b")
    case $kind in
      quadlet) dst=$qdir/$b ;;
      unit) dst=$sdir/$b ;;
      unsupported) q_errs+=("$b: .pod/.build are not supported by podman 4.9.3"); continue ;;
      *) q_errs+=("$b: unknown file type (config files belong in $out/config/)"); continue ;;
    esac
    q_srcs+=("$f") q_dsts+=("$dst")
  done
  if [[ -d $out/config ]]; then
    while IFS= read -r -d '' f; do
      rel=${f#"$out"/config/}
      q_srcs+=("$f") q_dsts+=("$cdir/$rel")
    done < <(find "$out/config" -type f -print0 | sort -z)
  fi
  ((${#q_srcs[@]})) || ql_die "ql_install_files: nothing to install in $out"

  local -A q_mf=() q_newmf=() q_inset=() q_pend=() q_changedq=() q_gone=()
  _ql_manifest_read "$app" q_mf
  local -a q_changed=() q_adopt=() q_modified=()
  local i a
  for a in ${_QL_ADOPTED[@]+"${_QL_ADOPTED[@]}"}; do q_gone["$a"]=1; done
  for i in "${!q_srcs[@]}"; do
    f=${q_srcs[$i]} dst=${q_dsts[$i]}
    q_inset[$dst]=1
    if owner=$(_ql_owner_of "$dst" "$app"); then q_errs+=("$dst belongs to app '$owner'"); continue; fi
    if { [[ -e $dst || -L $dst ]]; } && [[ -z ${q_gone[$dst]+x} ]]; then
      if [[ ! -L $dst ]] && cmp -s -- "$f" "$dst"; then continue; fi
      if [[ -z ${q_mf[$dst]+x} ]]; then
        if [[ $dst == "$sdir"/* ]]; then
          q_errs+=("$dst exists and is not ours (a legacy unit?). Stop/disable it and move it away first")
          continue
        fi
        q_adopt+=("$dst")
      elif [[ -L $dst || $(_ql_sha "$dst") != "${q_mf[$dst]}" ]]; then
        q_modified+=("$dst")
      fi
    fi
    q_changed+=("$i")
  done
  if ((${#q_errs[@]})); then
    printf '  %s\n' "${q_errs[@]}" >&2
    ql_die "ql_install_files: refusing to install $app (nothing was changed)"
  fi

  local -a q_stale=()
  for dst in "${!q_mf[@]}"; do [[ -n ${q_inset[$dst]+x} ]] || q_stale+=("$dst"); done

  if _ql_dry; then
    for i in "${q_changed[@]}"; do ql_info "[dry-run] would write ${q_dsts[$i]}"; done
    for dst in "${q_stale[@]}"; do ql_info "[dry-run] installed earlier, not in this set: $dst"; done
    _ql_print_changed "$out" "${q_srcs[@]}" -- "${q_changed[@]}"
    return 0
  fi

  for dst in "${q_adopt[@]}"; do _ql_backup_copy "$app" "$dst" "adopting existing file"; done
  for dst in "${q_modified[@]}"; do [[ -L $dst ]] || _ql_backup_copy "$app" "$dst" "overwriting a locally modified file"; done

  local tmp mode
  for i in "${q_changed[@]}"; do
    f=${q_srcs[$i]} dst=${q_dsts[$i]}
    mkdir -p -- "${dst%/*}" || ql_die "cannot create ${dst%/*}"
    tmp=$(mktemp "${dst%/*}/.${dst##*/}.ql-tmp.XXXXXX") || ql_die "cannot write in ${dst%/*}"
    mode=$(stat -c %a -- "$f")
    if ! { cp -- "$f" "$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$dst"; }; then
      rm -f -- "$tmp"
      ql_die "cannot install $dst"
    fi
  done

  # manifest: this set + earlier files still on disk
  for i in "${!q_srcs[@]}"; do
    sha=$(_ql_sha "${q_dsts[$i]}") || ql_die "cannot hash ${q_dsts[$i]}"
    q_newmf[${q_dsts[$i]}]=$sha
  done
  for dst in "${q_stale[@]}"; do q_newmf[$dst]=${q_mf[$dst]}; done
  # shellcheck disable=SC2034 # q_newmf is passed by name
  _ql_manifest_write "$app" q_newmf

  # pending restarts
  _ql_set_load "$(_ql_pending "$app")" q_pend
  local u r
  for i in "${q_changed[@]}"; do
    b=${q_dsts[$i]##*/}
    [[ ${q_dsts[$i]} == "$cdir"/* ]] && continue
    u=$(_ql_unit_for "$b")
    [[ -n $u ]] && q_pend[$u]=1
    case $b in *.volume | *.network | *.image) q_changedq[$b]=1 ;; esac
  done
  if ((${#q_changedq[@]})); then
    for i in "${!q_srcs[@]}"; do
      b=${q_dsts[$i]##*/}
      case $b in *.container | *.kube) ;; *) continue ;; esac
      while IFS= read -r r; do
        if [[ -n $r && -n ${q_changedq[$r]+x} ]]; then q_pend[$(_ql_unit_for "$b")]=1; fi
      done < <(_ql_refs "${q_srcs[$i]}")
    done
  fi
  _ql_set_save "$(_ql_pending "$app")" q_pend

  _ql_print_changed "$out" "${q_srcs[@]}" -- "${q_changed[@]}"
  ql_info "$app: ${#q_changed[@]} of ${#q_srcs[@]} file(s) changed"
  if ((${#q_stale[@]})); then
    if ((prune)); then
      local -a q_stale_names=()
      for dst in "${q_stale[@]}"; do
        if [[ $dst == "$cdir"/* ]]; then q_stale_names+=("config/${dst#"$cdir"/}"); else q_stale_names+=("${dst##*/}"); fi
      done
      ql_remove_files "$app" "${q_stale_names[@]}"
    else
      ql_warn "$app: installed earlier but not in this set (kept; remove with ql_remove_files or --prune): ${q_stale[*]}"
    fi
  fi
  return 0
}

# _ql_print_changed <out_dir> <src...> -- <index...>: stdout list of changed files
_ql_print_changed() {
  local out=$1 i f
  shift
  local -a q_all=()
  while (($#)) && [[ $1 != -- ]]; do q_all+=("$1"); shift; done
  shift
  for i in "$@"; do
    f=${q_all[$i]}
    if [[ $f == "$out"/config/* ]]; then printf 'config/%s\n' "${f#"$out"/config/}"; else printf '%s\n' "${f##*/}"; fi
  done
}

# ql_remove_files <app> <file...>: stop the units of the given installed files (basenames,
# or config/<path>), disable plain units, delete the files, drop them from the manifest and
# pending set, daemon-reload. For deselected optional units (--no-ml, --no-runners, ...).
ql_remove_files() {
  local app=${1:?usage: ql_remove_files <app> <file...>}
  shift
  _ql_need_app "$app"
  (($#)) || return 0
  local -A q_mf=() q_pend=()
  _ql_manifest_read "$app" q_mf
  _ql_set_load "$(_ql_pending "$app")" q_pend
  local want p hit u cdir
  cdir="$(_ql_config_root)/$app"
  local -a q_paths=()
  for want in "$@"; do
    hit=''
    for p in "${!q_mf[@]}"; do
      if [[ $want == config/* && $p == "$cdir/${want#config/}" ]] || [[ $want != config/* && ${p##*/} == "$want" && $p != "$cdir"/* ]]; then hit=$p; break; fi
    done
    [[ -n $hit ]] || ql_die "ql_remove_files: $want is not installed by $app"
    q_paths+=("$hit")
  done
  for p in "${q_paths[@]}"; do
    u=$(_ql_unit_for "${p##*/}")
    [[ $p == "$cdir"/* ]] && u=''
    if _ql_dry; then ql_info "[dry-run] would stop ${u:-nothing} and remove $p"; continue; fi
    if [[ -n $u ]]; then
      _ql_sc stop "$u" >/dev/null 2>&1 || ql_warn "could not stop $u"
      [[ $(_ql_kind "${p##*/}") == unit ]] && { _ql_sc disable "$u" >/dev/null 2>&1 || true; }
      unset "q_pend[$u]"
    fi
    if [[ -f $p && ! -L $p && $(_ql_sha "$p") != "${q_mf[$p]}" ]]; then _ql_backup_copy "$app" "$p" "removing a locally modified file"; fi
    rm -f -- "$p" || ql_die "cannot remove $p"
    unset "q_mf[$p]"
    ql_info "removed $p"
  done
  _ql_dry && return 0
  _ql_manifest_write "$app" q_mf
  _ql_set_save "$(_ql_pending "$app")" q_pend
  _ql_sc daemon-reload || ql_die "systemctl --user daemon-reload failed"
  return 0
}

# ql_mark_changed <app> <unit...>: add units to the pending-restart set (e.g. after a
# rendered config/ file or a secret they read changed).
ql_mark_changed() {
  local app=${1:?usage: ql_mark_changed <app> <unit...>} u
  shift
  _ql_need_app "$app"
  local -A q_pend=()
  _ql_set_load "$(_ql_pending "$app")" q_pend
  for u in "$@"; do q_pend[$u]=1; done
  _ql_dry || _ql_set_save "$(_ql_pending "$app")" q_pend
}

# ql_apply_units <app> <unit...>
#   daemon-reload; every unit must be loaded, and a unit generated from one of the app's
#   Quadlet files must come from the generator dir (else it is shadowed). Then: enable plain
#   units whose UnitFileState is "disabled" (timers, targets), restart units in the pending
#   set (plus pending -volume/-network/-image services of the app), start the rest when
#   inactive. Units in QL_HOLD_UNITS are started when inactive but never restarted (they
#   stay pending). Successfully restarted units leave the pending set.
ql_apply_units() {
  local app=${1:?usage: ql_apply_units <app> <unit...>}
  shift
  _ql_need_app "$app"
  (($#)) || ql_die "ql_apply_units: no units given"
  local u p load frag ufs state
  local -A q_mf=() q_genunits=() q_pend=() q_seen=() q_inrestart=()
  local -a q_restart=() q_start=() q_enable=() q_held=()
  _ql_manifest_read "$app" q_mf
  for p in "${!q_mf[@]}"; do
    [[ $(_ql_kind "${p##*/}") == quadlet ]] && q_genunits[$(_ql_unit_for "${p##*/}")]=1
  done
  _ql_set_load "$(_ql_pending "$app")" q_pend
  if _ql_dry; then
    ql_info "[dry-run] would daemon-reload; pending restarts: ${!q_pend[*]}; units: $*"
    return 0
  fi
  _ql_sc daemon-reload || ql_die "systemctl --user daemon-reload failed"
  for u in $(printf '%s\n' "${!q_pend[@]}" | LC_ALL=C sort); do
    case $u in *-volume.service | *-network.service | *-image.service)
      if [[ -n ${q_genunits[$u]+x} ]]; then q_restart+=("$u"); q_inrestart[$u]=1; fi ;;
    esac
  done
  for u in "$@"; do
    [[ -n ${q_seen[$u]+x} ]] && continue
    q_seen[$u]=1
    load=$(_ql_sc_show "$u" LoadState)
    [[ $load == loaded ]] || ql_die "$u is not loaded (LoadState=${load:-?}). For a Quadlet unit run: QUADLET_UNIT_DIRS=$(_ql_quadlet_dir) $(_ql_quadlet_bin) -dryrun -user"
    if [[ -n ${q_genunits[$u]+x} ]]; then
      frag=$(_ql_sc_show "$u" FragmentPath)
      [[ $frag == */systemd/generator/* ]] || ql_die "$u is loaded from $frag, which shadows the Quadlet-generated unit (see ql_check_unit_shadow)"
    fi
    ufs=$(_ql_sc_show "$u" UnitFileState)
    [[ $ufs == disabled ]] && q_enable+=("$u")
    state=$(_ql_sc is-active "$u" 2>/dev/null || true)
    if [[ -n ${q_pend[$u]+x} ]]; then
      if _ql_in_words "$u" "${QL_HOLD_UNITS:-}" && [[ $state == active || $state == activating ]]; then
        q_held+=("$u")
        continue
      fi
      [[ -n ${q_inrestart[$u]+x} ]] || { q_restart+=("$u"); q_inrestart[$u]=1; }
    else
      case $state in active | activating | reloading | refreshing) ;; *) q_start+=("$u") ;; esac
    fi
  done
  if ((${#q_enable[@]})); then
    _ql_sc enable "${q_enable[@]}" >/dev/null 2>&1 || ql_die "systemctl --user enable ${q_enable[*]} failed"
    ql_info "enabled: ${q_enable[*]}"
  fi
  if ((${#q_restart[@]})); then
    ql_info "restarting (changed): ${q_restart[*]}"
    _ql_sc restart "${q_restart[@]}" || ql_die "restart failed; see: journalctl --user -u ${q_restart[0]} -n 50"
    for u in "${q_restart[@]}"; do unset "q_pend[$u]"; done
  fi
  if ((${#q_start[@]})); then
    ql_info "starting: ${q_start[*]}"
    _ql_sc start "${q_start[@]}" || ql_die "start failed; see: journalctl --user -u ${q_start[0]} -n 50"
  fi
  if ((${#q_held[@]})); then
    ql_warn "changed but NOT restarted (QL_HOLD_UNITS): ${q_held[*]}. Apply with the repo's upgrade.sh."
  fi
  _ql_set_save "$(_ql_pending "$app")" q_pend
  ((${#q_restart[@]} + ${#q_start[@]})) || ql_info "$app: nothing to restart or start"
  return 0
}

# ---------------------------------------------------------------------------------------
# waits (return 1 on timeout, never exit)
# ---------------------------------------------------------------------------------------
# ql_wait_until <timeout_s> <description> <cmd...>
ql_wait_until() {
  local timeout=${1:?usage: ql_wait_until <timeout_s> <description> <cmd...>} desc=${2:?usage: ql_wait_until <timeout_s> <description> <cmd...>}
  shift 2
  local deadline=$((SECONDS + timeout))
  while :; do
    "$@" && return 0
    ((SECONDS >= deadline)) && { ql_warn "timed out after ${timeout}s waiting for $desc"; return 1; }
    sleep "${QL_POLL_INTERVAL:-2}"
  done
}

# ql_wait_container_healthy <name> <timeout_s>
#   With a HealthCmd: until podman reports "healthy" (QL_HEALTH_ACTIVE=1 additionally runs
#   `podman healthcheck run` each poll; note manual runs count toward HealthOnFailure).
#   Without one: until it has been running with the same StartedAt for QL_WAIT_STABLE_S (5).
ql_wait_container_healthy() {
  local name=${1:?usage: ql_wait_container_healthy <name> <timeout_s>} timeout=${2:?usage: ql_wait_container_healthy <name> <timeout_s>}
  local deadline=$((SECONDS + timeout)) info st hc health started since=$SECONDS first='<none>' last=''
  local stable=${QL_WAIT_STABLE_S:-5}
  while :; do
    info=$(podman inspect --format '{{.State.Status}}|{{if .Config.Healthcheck}}hc{{end}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.State.StartedAt}}' "$name" 2>/dev/null) || info='absent|||'
    IFS='|' read -r st hc health started <<<"$info"
    last="status=$st${hc:+ health=${health:-starting}}"
    if [[ $st == running ]]; then
      if [[ -n $hc ]]; then
        if [[ $health == healthy ]]; then ql_info "$name is healthy"; return 0; fi
        if [[ ${QL_HEALTH_ACTIVE:-0} == 1 ]] && podman healthcheck run "$name" >/dev/null 2>&1; then
          ql_info "$name is healthy (active check)"
          return 0
        fi
      else
        if [[ $started != "$first" ]]; then first=$started since=$SECONDS; fi
        if ((SECONDS - since >= stable)); then ql_info "$name is running (no healthcheck)"; return 0; fi
      fi
    else
      first='<none>'
    fi
    if ((SECONDS >= deadline)); then
      ql_warn "$name not healthy after ${timeout}s ($last). See: journalctl --user -u <unit> -n 50; podman logs --tail 50 $name"
      return 1
    fi
    sleep "${QL_POLL_INTERVAL:-2}"
  done
}

# ql_wait_http <url> <expected_codes_regex> <timeout_s>
#   Polls until the HTTP status matches ^(regex)$, e.g. '200|401', '2..'. Connection errors
#   count as 000. QL_HTTP_INSECURE=1 adds -k; QL_HTTP_HEADER_FILE adds -H @file (tokens stay
#   out of argv).
ql_wait_http() {
  local url=${1:?usage: ql_wait_http <url> <codes_regex> <timeout_s>} re=${2:?usage: ql_wait_http <url> <codes_regex> <timeout_s>} timeout=${3:?usage: ql_wait_http <url> <codes_regex> <timeout_s>}
  command -v curl >/dev/null 2>&1 || ql_die "curl not found"
  local rc=0
  # shellcheck disable=SC2319 # status 2 from [[ =~ ]] means an invalid regex
  [[ 000 =~ ^($re)$ ]] || rc=$?
  ((rc != 2)) || ql_die "ql_wait_http: invalid regex '$re'"
  local -a q_args=(-s -o /dev/null -w '%{http_code}' -m "${QL_HTTP_TIMEOUT:-5}")
  [[ ${QL_HTTP_INSECURE:-0} == 1 ]] && q_args+=(-k)
  [[ -n ${QL_HTTP_HEADER_FILE:-} ]] && q_args+=(-H "@$QL_HTTP_HEADER_FILE")
  local deadline=$((SECONDS + timeout)) code
  while :; do
    code=$(curl "${q_args[@]}" "$url" 2>/dev/null) || true
    [[ $code =~ ^[0-9]{3}$ ]] || code=000
    if [[ $code =~ ^($re)$ ]]; then ql_info "$url -> $code"; return 0; fi
    if ((SECONDS >= deadline)); then ql_warn "$url still returns $code after ${timeout}s (want $re)"; return 1; fi
    sleep "${QL_POLL_INTERVAL:-2}"
  done
}

# ---------------------------------------------------------------------------------------
# secrets
# ---------------------------------------------------------------------------------------
# _ql_random_alnum <len>: [A-Za-z0-9] from /dev/urandom, no pipes that can SIGPIPE
_ql_random_alnum() {
  local want=$1 out='' chunk
  while ((${#out} < want)); do
    chunk=$(head -c 768 /dev/urandom | base64 -w0) || return 1
    out+=${chunk//[!A-Za-z0-9]/}
  done
  printf '%s' "${out:0:want}"
}

# ql_secret_ensure <name> <random:<len> | file:<path> | env:<VAR>> [--update | --replace]
#   Creates the podman secret if missing; an existing one is kept. --update replaces it when
#   the file:/env: value differs; --replace always replaces (random: regenerates). Values
#   never reach argv, stdout, logs or xtrace. env:VAR reads QL_ENV[VAR] (ql_env_load), then a
#   shell variable VAR (so scripts can build derived values, e.g. a DATABASE_URL). Adds
#   label io.woowtech.app=$QL_APP and records the name for ql_uninstall_units --purge.
ql_secret_ensure() {
  local xt=0 rc=0
  [[ $- == *x* ]] && xt=1 && set +x
  _ql_secret_ensure "$@" || rc=$?
  ((xt)) && set -x
  return "$rc"
}

_ql_secret_ensure() {
  local name=${1:?usage: ql_secret_ensure <name> <random:N|file:PATH|env:VAR> [--update|--replace]} mode=${2:?usage: ql_secret_ensure <name> <random:N|file:PATH|env:VAR> [--update|--replace]}
  local policy=keep value='' path='' var len exists=0 rc=0 current src
  case ${3:-} in '') ;; --update) policy=update ;; --replace) policy=replace ;; *) ql_die "ql_secret_ensure: unknown option $3" ;; esac
  _ql_valid_name "$name" || ql_die "ql_secret_ensure: invalid secret name '$name'"
  podman secret exists "$name" >/dev/null 2>&1 || rc=$?
  case $rc in 0) exists=1 ;; 1) ;; *) ql_die "podman secret exists $name failed (rc=$rc)" ;; esac
  case $mode in
    random:*)
      len=${mode#random:}
      if ! [[ $len =~ ^[0-9]+$ ]] || ((len < 8 || len > 4096)); then ql_die "ql_secret_ensure $name: random length must be 8..4096"; fi
      src="random, $len chars"
      if ((exists)) && [[ $policy != replace ]]; then ql_info "secret $name exists (kept)"; _ql_secret_record "$name"; return 0; fi
      value=$(_ql_random_alnum "$len") || ql_die "cannot read /dev/urandom"
      ;;
    env:*)
      var=${mode#env:}
      _ql_valid_var "$var" || ql_die "ql_secret_ensure $name: invalid variable name '$var'"
      if [[ -n ${QL_ENV[$var]+x} ]]; then value=${QL_ENV[$var]}
      elif [[ -n ${!var+x} ]]; then value=${!var}
      else ql_die "ql_secret_ensure $name: $var is not set (env file or shell variable)"; fi
      [[ -n $value ]] || ql_die "ql_secret_ensure $name: $var is empty (podman secrets cannot be empty)"
      src="from $var"
      ;;
    file:*)
      path=${mode#file:}
      [[ -f $path && -r $path ]] || ql_die "ql_secret_ensure $name: cannot read $path"
      [[ -s $path ]] || ql_die "ql_secret_ensure $name: $path is empty"
      [[ $(stat -c %a -- "$path") =~ 00$ ]] || ql_warn "$path is readable by group/others; use chmod 600"
      src="from ${path##*/}"
      ;;
    *) ql_die "ql_secret_ensure $name: mode must be random:<len>, file:<path> or env:<VAR>" ;;
  esac
  if ((exists)) && [[ $policy != replace ]]; then
    if current=$(podman secret inspect --showsecret --format '{{.SecretData}}' "$name" 2>/dev/null); then
      if [[ -n $path ]]; then value=$(<"$path"); fi
      if [[ $current == "$value" ]]; then ql_info "secret $name exists and matches its source"; _ql_secret_record "$name"; return 0; fi
      if [[ $policy == keep ]]; then
        ql_warn "secret $name differs from its source ($src); kept. Use --update to replace it (a DB password must be changed in the DB first)"
        _ql_secret_record "$name"
        return 0
      fi
    elif [[ $policy == keep ]]; then
      ql_info "secret $name exists (kept)"
      _ql_secret_record "$name"
      return 0
    fi
  fi
  if _ql_dry; then
    if ((exists)); then ql_info "[dry-run] would replace secret $name ($src)"; else ql_info "[dry-run] would create secret $name ($src)"; fi
    return 0
  fi
  local -a q_args=(secret create)
  ((exists)) && q_args+=(--replace)
  [[ -n ${QL_APP:-} ]] && q_args+=(--label "io.woowtech.app=$QL_APP")
  if [[ -n $path ]]; then
    podman "${q_args[@]}" "$name" "$path" >/dev/null || ql_die "podman secret create $name failed"
  else
    printf '%s' "$value" | podman "${q_args[@]}" "$name" - >/dev/null || ql_die "podman secret create $name failed"
  fi
  value=''
  _ql_secret_record "$name"
  if ((exists)); then
    ql_warn "secret $name replaced ($src); restart the units that use it"
    # shellcheck disable=SC2034 # public: callers restart the units that read the secret
    QL_SECRET_CHANGED=1
  else
    ql_info "secret $name created ($src)"
  fi
  return 0
}

_ql_secret_record() {
  [[ -n ${QL_APP:-} ]] || return 0
  _ql_dry && return 0
  local -A q_s=()
  local f
  f="$(_ql_state_dir "$QL_APP")/secrets"
  _ql_set_load "$f" q_s
  [[ -n ${q_s[$1]+x} ]] && return 0
  q_s[$1]=1
  _ql_set_save "$f" q_s
}

# ---------------------------------------------------------------------------------------
# backups (0600 files in 0700 dirs, written to *.partial then renamed, + .sha256)
# ---------------------------------------------------------------------------------------
_ql_mkdir_private() {
  [[ -d $1 ]] && return 0
  (umask 077 && mkdir -p -- "$1") || ql_die "cannot create $1"
}

# ql_backup_volume <vol> <dest_dir>: podman volume export -> <dest_dir>/<vol>-<ts>.tar; prints the path
ql_backup_volume() {
  local vol=${1:?usage: ql_backup_volume <vol> <dest_dir>} dest=${2:?usage: ql_backup_volume <vol> <dest_dir>} users out
  podman volume exists "$vol" >/dev/null 2>&1 || ql_die "volume $vol does not exist"
  _ql_mkdir_private "$dest"
  users=$(podman ps --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null || true)
  [[ -z $users ]] || ql_warn "volume $vol is in use by running container(s): ${users//$'\n'/ }; the export may be inconsistent (stop them, or use a logical dump for databases)"
  out=$dest/$vol-$(date +%Y%m%d-%H%M%S).tar
  [[ ! -e $out ]] || ql_die "$out already exists"
  if ! (umask 077 && podman volume export "$vol" -o "$out.partial"); then
    rm -f -- "$out.partial"
    ql_die "podman volume export $vol failed"
  fi
  mv -f -- "$out.partial" "$out" || ql_die "cannot rename $out.partial"
  (cd -- "$dest" && umask 077 && sha256sum -- "${out##*/}" >"${out##*/}.sha256") || ql_die "cannot checksum $out"
  ql_info "exported volume $vol -> $out ($(du -h -- "$out" | cut -f1))"
  printf '%s\n' "$out"
}

# ql_backup_dir <path> <dest_tgz> [--exclude PATTERN]...: `podman unshare tar` (reads files
# owned by container subuids), numeric owners kept; prints the path
ql_backup_dir() {
  local path=${1:?usage: ql_backup_dir <path> <dest_tgz> [--exclude PATTERN]...} dest=${2:?usage: ql_backup_dir <path> <dest_tgz> [--exclude PATTERN]...}
  shift 2
  local -a q_ex=()
  while (($#)); do
    case $1 in
      --exclude) q_ex+=("--exclude=${2:?--exclude needs a pattern}"); shift ;;
      *) ql_die "ql_backup_dir: unknown option $1" ;;
    esac
    shift
  done
  path=$(ql_expand_home "$path")
  [[ -d $path ]] || ql_die "ql_backup_dir: $path is not a directory"
  [[ ! -e $dest ]] || ql_die "ql_backup_dir: $dest already exists"
  local parent base rc=0
  parent=$(cd -- "$(dirname -- "$path")" && pwd -P) || ql_die "cannot resolve $path"
  base=$(basename -- "$path")
  _ql_mkdir_private "$(dirname -- "$dest")"
  (umask 077 && podman unshare tar --numeric-owner -czf "$dest.partial" "${q_ex[@]}" -C "$parent" -- "$base") || rc=$?
  if ((rc == 1)); then
    ql_warn "tar reported files that changed while being read ($path); stop the app for a consistent backup"
  elif ((rc != 0)); then
    rm -f -- "$dest.partial"
    ql_die "podman unshare tar of $path failed (rc=$rc)"
  fi
  mv -f -- "$dest.partial" "$dest" || ql_die "cannot rename $dest.partial"
  (cd -- "$(dirname -- "$dest")" && umask 077 && sha256sum -- "${dest##*/}" >"${dest##*/}.sha256") || ql_die "cannot checksum $dest"
  ql_info "archived $path -> $dest ($(du -h -- "$dest" | cut -f1))"
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------------------
# _ql_label_owner <volume|network> <name>: first io.woowtech.{app,stack,package} label value
_ql_label_owner() {
  podman "$1" inspect --format '{{with .Labels}}{{or (index . "io.woowtech.app") (index . "io.woowtech.stack") (index . "io.woowtech.package")}}{{end}}' "$2" 2>/dev/null || true
}

# ql_uninstall_units <app> [--purge]
#   Stops the app's units (timers first), disables its plain units, removes every file in its
#   manifest (a locally modified one is copied to the state dir first), daemon-reload,
#   reset-failed. Volumes, networks, secrets, images, bind-mounted data and podman.socket are
#   kept. --purge (explicit) also removes the volumes/networks named by its .volume/.network
#   files (skipping ones another app installs or labels, and ones in use), the secrets
#   recorded by ql_secret_ensure, and the state dir. The env file is never deleted.
ql_uninstall_units() {
  local app=${1:?usage: ql_uninstall_units <app> [--purge]} purge=0
  case ${2:-} in '') ;; --purge) purge=1 ;; *) ql_die "ql_uninstall_units: unknown option ${2}" ;; esac
  _ql_need_app "$app"
  local p b u v sdir cdir
  sdir=$(_ql_sd_user_dir) cdir="$(_ql_config_root)/$app"
  local -A q_mf=()
  _ql_manifest_read "$app" q_mf
  local -a q_timers=() q_plain=() q_gen=() q_infra=() q_vols=() q_nets=()
  for p in "${!q_mf[@]}"; do
    b=${p##*/}
    [[ $p == "$cdir"/* ]] && continue
    u=$(_ql_unit_for "$b")
    case $b in
      *.volume)
        q_infra+=("$u")
        if [[ -f $p ]]; then v=$(_ql_key_value "$p" Volume VolumeName); [[ -n $v ]] && q_vols+=("$v"); fi ;;
      *.network)
        q_infra+=("$u")
        if [[ -f $p ]]; then v=$(_ql_key_value "$p" Network NetworkName); [[ -n $v ]] && q_nets+=("$v"); fi ;;
      *.image) q_infra+=("$u") ;;
      *.container | *.kube) q_gen+=("$u") ;;
      *.timer) q_timers+=("$u") ;;
      *) [[ $p == "$sdir"/* ]] && q_plain+=("$u") ;;
    esac
  done
  if ((${#q_mf[@]} == 0)); then
    ql_info "$app: no installed files recorded"
  fi
  if _ql_dry; then
    ql_info "[dry-run] would stop: ${q_timers[*]} ${q_plain[*]} ${q_gen[*]} ${q_infra[*]}"
    ql_info "[dry-run] would remove: ${!q_mf[*]}"
    ((purge)) && ql_info "[dry-run] --purge would remove volumes: ${q_vols[*]:-none}; networks: ${q_nets[*]:-none}; recorded secrets; $(_ql_state_dir "$app")"
    return 0
  fi
  for u in "${q_timers[@]}" "${q_plain[@]}" "${q_gen[@]}" "${q_infra[@]}"; do
    [[ $(_ql_sc_show "$u" LoadState) == loaded ]] || continue
    _ql_sc stop "$u" >/dev/null 2>&1 || ql_warn "could not stop $u"
  done
  for u in "${q_timers[@]}" "${q_plain[@]}"; do
    _ql_sc disable "$u" >/dev/null 2>&1 || true
  done
  for p in "${!q_mf[@]}"; do
    [[ -e $p || -L $p ]] || continue
    if [[ -f $p && ! -L $p && $(_ql_sha "$p") != "${q_mf[$p]}" ]]; then _ql_backup_copy "$app" "$p" "removing a locally modified file"; fi
    rm -f -- "$p" || ql_warn "could not remove $p"
  done
  rm -f -- "$(_ql_manifest "$app")" "$(_ql_pending "$app")"
  _ql_sc daemon-reload || ql_warn "systemctl --user daemon-reload failed"
  for u in "${q_timers[@]}" "${q_plain[@]}" "${q_gen[@]}" "${q_infra[@]}"; do
    _ql_sc reset-failed "$u" >/dev/null 2>&1 || true
  done
  ql_info "$app: units stopped and ${#q_mf[@]} installed file(s) removed"
  if ((!purge)); then
    ql_info "$app: kept volumes (${q_vols[*]:-none}), networks (${q_nets[*]:-none}), secrets, images and data. Use --purge to delete them."
    return 0
  fi

  # --purge
  local -A q_foreignv=() q_foreignn=()
  local mfo q
  for mfo in "$(_ql_state_root)"/*/manifest; do
    [[ -f $mfo && $mfo != "$(_ql_manifest "$app")" ]] || continue
    while read -r _ q; do
      [[ -f $q ]] || continue
      case $q in
        *.volume) v=$(_ql_key_value "$q" Volume VolumeName); [[ -n $v ]] && q_foreignv[$v]=1 ;;
        *.network) v=$(_ql_key_value "$q" Network NetworkName); [[ -n $v ]] && q_foreignn[$v]=1 ;;
      esac
    done <"$mfo"
  done
  local owner
  for v in "${q_vols[@]}"; do
    if [[ -n ${q_foreignv[$v]+x} ]]; then ql_warn "keeping volume $v: another app installs it"; continue; fi
    podman volume exists "$v" >/dev/null 2>&1 || continue
    owner=$(_ql_label_owner volume "$v")
    if [[ -n $owner && $owner != "$app" ]]; then ql_warn "keeping volume $v: labeled for '$owner'"; continue; fi
    if podman volume rm "$v" >/dev/null 2>&1; then ql_info "removed volume $v"; else ql_warn "could not remove volume $v (in use?)"; fi
  done
  for v in "${q_nets[@]}"; do
    if [[ -n ${q_foreignn[$v]+x} ]]; then ql_warn "keeping network $v: another app installs it"; continue; fi
    podman network exists "$v" >/dev/null 2>&1 || continue
    owner=$(_ql_label_owner network "$v")
    if [[ -n $owner && $owner != "$app" ]]; then ql_warn "keeping network $v: labeled for '$owner'"; continue; fi
    if podman network rm "$v" >/dev/null 2>&1; then ql_info "removed network $v"; else ql_warn "could not remove network $v (in use?)"; fi
  done
  local sf s
  sf="$(_ql_state_dir "$app")/secrets"
  if [[ -f $sf ]]; then
    while IFS= read -r s; do
      [[ -n $s ]] || continue
      podman secret exists "$s" >/dev/null 2>&1 || continue
      if podman secret rm "$s" >/dev/null 2>&1; then ql_info "removed secret $s"; else ql_warn "could not remove secret $s"; fi
    done <"$sf"
  fi
  rm -rf -- "$(_ql_state_dir "$app")"
  ql_info "$app: purged (the env file in $(_ql_config_root)/$app/ and bind-mounted data dirs are left for you to delete)"
  return 0
}
