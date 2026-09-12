#!/usr/bin/env bash
# tests/cf-gate-ingress.sh: unit tests for cf_ingress_map (scripts/lib/cf-gate.sh), the probe
# that turns cloudflared's /config into the "hostname origin" map cf_baseline and cf_gate_check
# compare a swap against.
#
# The contract this pins is the one production broke on toypark1234: cloudflared emits the
# catch-all rule with the hostname key PRESENT AND EMPTY ({"hostname": "", "service":
# "http_status:404"}), so `r.get("hostname", "*")` never fires its default. The line then
# started with a space, cf_baseline's `read -r host _` took the SERVICE as a hostname, curled
# "http_status:404" into a 000, and the "already returns 000/530" guard refused the migration.
# The harness only caught that indirectly, and only once its curl mock stopped emitting a
# shape cloudflared does not produce -- hence this direct test.
#
# The fixtures below carry the full rule shape of a live connector (cloudflared 2026.6.1,
# remote-managed config, read from http://127.0.0.1:20241/config): every rule has hostname,
# path, service, Handlers and originRequest, and only the hostnames are anonymised.
#
# Everything is driven by a curl stub on PATH, so this needs no tunnel and no network.
#
#   tests/cf-gate-ingress.sh [filter]
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-gate-ingress.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../scripts/lib/cf-gate.sh
. "$REPO/scripts/lib/cf-gate.sh"
filter=${1:-}
fails=0 ran=0

# originRequest is by far the bulk of a real rule and is never meant to reach the output, so
# it carries a token-shaped blob here: the assertions below prove the probe emits the hostname
# and service columns only. Allowlisted in tests/no-secrets.sh by the not-a-real prefix.
TOKEN=not-a-real-eyJhIjoiVEVTVC1PTkxZIiwidCI6IjAwMDAwMDAwIn0
ORIGIN_REQUEST="{\"connectTimeout\":30,\"tlsTimeout\":10,\"tcpKeepAlive\":30,\
\"noHappyEyeballs\":false,\"keepAliveTimeout\":90,\"keepAliveConnections\":100,\
\"httpHostHeader\":\"\",\"originServerName\":\"\",\"matchSNItoHost\":false,\"caPool\":\"\",\
\"noTLSVerify\":false,\"disableChunkedEncoding\":false,\"bastionMode\":false,\
\"proxyAddress\":\"127.0.0.1\",\"proxyPort\":0,\"proxyType\":\"$TOKEN\",\"ipRules\":null,\
\"http2Origin\":false,\"access\":{\"teamName\":\"\",\"audTag\":null}}"

# rule <hostname-json> <service>: one ingress rule with the key set a real connector sends
rule() { printf '{"hostname":%s,"path":null,"service":"%s","Handlers":null,"originRequest":%s}' "$1" "$2" "$ORIGIN_REQUEST"; }

# the stub is only prepended to PATH: cf_ingress_map also needs python3 and sort
mkdir -p "$TMP/bin"
PATH=$TMP/bin:$PATH

# serves <body>: a curl that answers GET http://$METRICS_ADDR/config with this body, and
# refuses anything else the way the real metrics server would for an unknown path.
serves() {
  printf '%s' "$1" >"$TMP/config.json"
  cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case $a in http*) url=$a ;; esac; done
[[ ${url:-} == "http://127.0.0.1:20241/config" ]] || exit 6
cat "${CF_FIXTURE:?}"
STUB
  chmod +x "$TMP/bin/curl"
  export CF_FIXTURE=$TMP/config.json
}
# refuses <rc>: nothing listens on the metrics port (curl exits 7), the normal state of an
# unconfigured, stopped or crashed tunnel
refuses() {
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
}

# quoted <label> <text>: the text, one indented "|" line each, so an empty or space-prefixed
# line is visible in a failure report
quoted() {
  local l
  printf '      %s\n' "$1"
  while IFS= read -r l; do printf '        |%s|\n' "$l"; done <<<"$2"
}
# check <name> <expected stdout>: cf_ingress_map must print exactly this and succeed
check() {
  local name=$1 want=$2 got rc=0 bad=''
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  got=$(cf_ingress_map) || rc=$?
  ((rc == 0)) || bad+=" exit=$rc(want 0)"
  [[ $got == "$want" ]] || bad+=' output differs'
  [[ $got != *"$TOKEN"* ]] || bad+=' the output leaked originRequest'
  if [[ -z $bad ]]; then
    echo "ok    $name"
  else
    echo "FAIL  $name:$bad"
    [[ $got == "$want" ]] || { quoted got: "$got"; quoted want: "$want"; }
    fails=$((fails + 1))
  fi
}
# no_leading_blank <map>: no output line may start with whitespace. This is the production
# symptom in one assertion: print("", svc) emitted " http_status:404", and `read -r host _`
# then swallowed the space and took the service as the hostname.
no_leading_blank() { ! grep -q '^[[:space:]]' <<<"$1"; }
# claim <name> <description> <cmd...>: a single assertion about the current fixture
claim() {
  local name=$1 what=$2
  shift 2
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  if "$@"; then
    echo "ok    $name"
  else
    echo "FAIL  $name: $what"
    fails=$((fails + 1))
  fi
}

# ---- 1. the real remote-managed payload -------------------------------------------------
# Three routes plus the catch-all, in the order cloudflared sends them (not sorted).
REAL="{\"version\":29,\"config\":{\"ingress\":[\
$(rule '"ha.example.io"' 'http://localhost:8123'),\
$(rule '"ssh.example.io"' 'ssh://localhost:22'),\
$(rule '"immich.example.io"' 'http://localhost:2283'),\
$(rule '""' 'http_status:404')\
],\"originRequest\":$ORIGIN_REQUEST,\"warp-routing\":{\"enabled\":false}}}"
serves "$REAL"
# Sorted LC_ALL=C, so '*' (0x2a) sorts ahead of the letters.
check real-cloudflared-config '* http_status:404
ha.example.io http://localhost:8123
immich.example.io http://localhost:2283
ssh.example.io ssh://localhost:22'

MAP=$(cf_ingress_map)
claim every-rule-survives 'one output line per ingress rule (4)' \
  test "$(wc -l <<<"$MAP")" -eq 4
claim every-pair-survives 'each hostname keeps its own service' \
  test "$(grep -c -F -x -e 'ha.example.io http://localhost:8123' -e 'ssh.example.io ssh://localhost:22' -e 'immich.example.io http://localhost:2283' -e '* http_status:404' <<<"$MAP")" -eq 4
# The production symptom, stated directly: the empty hostname became a leading space, so the
# service string moved into the hostname column.
claim no-line-starts-blank 'a line starting with a space means the empty hostname fell through' \
  no_leading_blank "$MAP"
claim catch-all-is-star 'the catch-all must be exactly one "*" line' \
  test "$(grep -c '^\* ' <<<"$MAP")" -eq 1
# cf_baseline reads this map with `while read -r host _` and curls every host that is not '*'.
claim baseline-reads-only-hostnames 'cf_baseline must never curl a service string as a hostname' \
  test "$(while read -r host _; do [[ $host == '*' ]] || printf '%s\n' "$host"; done <<<"$MAP" | LC_ALL=C sort | tr '\n' ' ')" = 'ha.example.io immich.example.io ssh.example.io '

# ---- 2. the other spelling of "no hostname" ----------------------------------------------
# A locally-managed tunnel's config.yml catch-all can omit the key altogether, so `or` has to
# answer both shapes -- the absent key is what the harness used to mock, and the only one the
# dict default ever covered.
serves "{\"version\":3,\"config\":{\"ingress\":[\
$(rule '"only.example.io"' 'http://localhost:8080'),\
{\"service\":\"http_status:404\"}\
]}}"
check catch-all-key-absent '* http_status:404
only.example.io http://localhost:8080'

# A null hostname is the third spelling json.load can hand back; it must not print "None".
serves "{\"version\":4,\"config\":{\"ingress\":[$(rule 'null' 'http_status:404')]}}"
check catch-all-hostname-null '* http_status:404'

# ---- 3. ordering is the map's identity ----------------------------------------------------
# cf_gate_check compares sha256 of this output before and after the swap, so the sort must not
# depend on the order cloudflared happens to send the rules in.
serves "{\"version\":29,\"config\":{\"ingress\":[\
$(rule '"zz.example.io"' 'http://localhost:1'),\
$(rule '""' 'http_status:404'),\
$(rule '"Aa.example.io"' 'http://localhost:2'),\
$(rule '"aa.example.io"' 'http://localhost:3')\
]}}"
check sorted-lc-all-c '* http_status:404
Aa.example.io http://localhost:2
aa.example.io http://localhost:3
zz.example.io http://localhost:1'

# ---- 4. the sentinels cf_baseline depends on ----------------------------------------------
# Both of these must be empty output AND exit 0: the callers run under `set -euo pipefail`,
# where a non-zero here would kill the migration instead of producing a vacuous baseline that
# cf_baseline then refuses with its own message.
serves 'not json'
check unparseable-body-is-empty ''

serves '{"version":29}'
check config-without-ingress-is-empty ''

refuses 7
check metrics-port-refused-is-empty ''

refuses 28
check metrics-timeout-is-empty ''

if ((fails == 0)); then
  echo "cf-gate-ingress: $ran case(s) passed"
else
  echo "cf-gate-ingress: $fails of $ran case(s) failed"
  exit 1
fi
