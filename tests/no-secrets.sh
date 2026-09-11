#!/usr/bin/env bash
# tests/no-secrets.sh: refuse to ship a credential in this repo. The tunnel token, the
# CSRF secret and any htpasswd live on the host (the data volume, ~/.config/woow-cf-tunnel),
# never here; config/*.env.example holds settings only.
#
# Checked everywhere: private keys, and KEY=<16+ chars> for password/secret/token/api-key
# names. Checked outside tests/ and frontend/ (which carry obvious placeholders): strings
# that look like a Cloudflare tunnel token (a long base64url blob starting with eyJ).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0
report() { echo "possible secret: $1"; rc=1; }

while IFS= read -r hit; do report "$hit"; done < <(
  grep -rIn --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules \
    -E 'BEGIN (RSA|OPENSSH|EC|PRIVATE) (PRIVATE )?KEY|[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY)[A-Za-z0-9_]*=["'"'"']?[A-Za-z0-9+/_-]{16,}' . |
    grep -vE 'CSRF_SECRET=\$|SMOKE_AUTH_PASS=ci-password-not-secret|test-csrf-secret-for-pytest|correct-horse-battery|rotated-password|second-user-password|ci-password-not-secret|not-a-real|tests/no-secrets\.sh'
)
while IFS= read -r hit; do report "$hit"; done < <(
  grep -rIn --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules \
    --exclude-dir=tests --exclude-dir=frontend -E 'eyJ[A-Za-z0-9_-]{30,}' .
)
for f in $(git ls-files 2>/dev/null); do
  case ${f##*/} in
    .tunnel_token | .csrf_secret | htpasswd | cert.pem | tunnel.json | *.tar) report "$f should never be committed" ;;
  esac
done
if ((rc == 0)); then echo "no-secrets: clean"; fi
exit "$rc"
