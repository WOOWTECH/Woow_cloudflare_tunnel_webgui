# Changelog

## 1.1.0 — Quadlet + systemd as the primary deployment

**Deployment**
- Rootless Podman Quadlet units under user systemd: `woow-cf-tunnel.container` (host
  network, GUI pinned to 127.0.0.1) and `woow-cf-tunnel-data.volume`, which adopts the
  existing data volume in place. Optional `woow-cf-tunnel-auth.container` adds an nginx
  Basic-auth front door.
- `scripts/`: `install.sh`, `upgrade.sh`, `uninstall.sh`, `backup.sh`, `restore.sh`,
  `migrate-legacy.sh`, `auth-passwd.sh`. Per-host values are rendered into the units at
  install time from `~/.config/woow-cf-tunnel/woow-cf-tunnel.env`.
- The image is built locally as `localhost/woow-cf-tunnel:<VERSION>-<git-sha12>` and the
  unit pins it with `Pull=never`. Publishing to GHCR is future work.
- Upgrades and legacy migrations run in a detached `systemd-run --user` watchdog that
  gates on edge connections, the ingress config version, the hostname map, podman health
  and every public hostname's HTTP code, soaks for 10 minutes, and rolls back on its own.

**Liveness**
- New container healthcheck (`/usr/local/bin/cf-webui-healthcheck`): the backend **and**
  cloudflared `/ready`. With `HealthOnFailure=kill` + `Restart=always`, a dead connector
  now recovers by itself; before this it stayed down while `/api/health` returned 200.

**Security**
- The tunnel token is passed to cloudflared with `--token-file`, so it no longer appears
  in any process argv (`ps`, `podman top`, `systemctl --user status`).
- cloudflared is pinned by version **and** SHA256; 2026.8.0 and 2026.8.1, which Cloudflare
  marked "Do not use", are refused at build time.
- The image's default command binds 127.0.0.1 instead of 0.0.0.0.
- Docs no longer claim the token is a Podman secret that never touches disk: it is a 0600
  file in the data volume, and the GUI has no login, so exposure rules are spelled out.

**Breaking**
- `docker-compose.yml` is gone; the last commit that ships it is tagged `compose-final`.
- `build_run_args()` no longer takes `token=`; callers pass `token_file=`.

## 1.0.0
- Single-container FastAPI + Vue GUI that supervises cloudflared directly, with token and
  local-managed modes, the setup wizard, live logs and the compose deployment.
