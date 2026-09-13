#!/usr/bin/env bash
# scripts/uninstall.sh: remove the woow-cf-tunnel Quadlet units. Keeps your data by default.
#
#   scripts/uninstall.sh                   stop and remove the units; keep the data volume,
#                                          the image, the env file and the htpasswd
#   scripts/uninstall.sh --purge [--yes]   also delete the data volume (THE TUNNEL TOKEN
#                                          LIVES THERE) after a final backup
#   scripts/uninstall.sh --dry-run         report what would be removed
#   scripts/uninstall.sh --force           allow it over an SSH session that rides the tunnel
#
# THIS STOPS THE TUNNEL. Every public hostname it serves goes down, including an SSH route.
# Never deleted here: the env file, the built images, podman.socket, and the legacy
# cf-tunnel-webgui unit (if you migrated, its file is still in ~/.config/systemd/user).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$HERE/lib/quadlet-lib.sh"
# shellcheck source=lib/cf-gate.sh
. "$HERE/lib/cf-gate.sh"
export QL_LOG_PREFIX=uninstall QL_APP=$CF_APP

QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
BACKUP_DIR=$HOME/backups/$CF_APP
purge=0 yes=0 force=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --force) force=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$CF_APP"

if cf_session_rides_tunnel && ((!force)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  ql_die "removing the tunnel would cut this session: $CF_SESSION_WHY. Reconnect over another path (the tailnet), or pass --force"
fi
if systemctl --user is-active --quiet "$NEW_UNIT" 2>/dev/null && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  n=$(cf_ready_conns)
  ((n < 1)) || ql_warn "the tunnel is serving with $n edge connection(s); removing it takes every public hostname down"
fi

if ((!purge)); then
  ql_uninstall_units "$CF_APP"
  ql_info "kept: the data volume (tunnel token), images, $HOME/.config/$CF_APP/ and your backups"
  exit 0
fi

vol=''
[[ -f $QUADLET_DIR/woow-cf-tunnel-data.volume ]] && vol=$(sed -n 's/^VolumeName=//p' "$QUADLET_DIR/woow-cf-tunnel-data.volume" | tail -n1)
if ((!yes)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  [[ -t 0 ]] || ql_die "--purge deletes the data volume ${vol:-}; add --yes to confirm non-interactively"
  ql_warn "--purge deletes volume ${vol:-<none>}: the tunnel token, settings and CSRF secret"
  read -r -p "Type '$CF_APP' to delete them: " answer
  [[ $answer == "$CF_APP" ]] || ql_die "aborted; nothing was deleted"
fi
if [[ -n $vol && ${QL_DRY_RUN:-0} != 1 ]] && podman volume exists "$vol"; then
  ql_info "final backup before --purge"
  systemctl --user stop "$NEW_UNIT" 2>/dev/null || true
  ql_backup_volume "$vol" "$BACKUP_DIR" >/dev/null
fi
ql_uninstall_units "$CF_APP" --purge
ql_info "the env file, the htpasswd and $BACKUP_DIR are left for you to delete (the backups contain the tunnel token)"
