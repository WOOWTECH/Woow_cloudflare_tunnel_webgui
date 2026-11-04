# Changelog

## 1.2.0 — feature parity with the Woow Cloudflared HA add-on (1.1.1)

**Added**
- **WOOW PaaS link** (`/paas` page, `/api/paas/*`). It uses the same flow and PaaS API as the
  add-on: device authorization, workspace and service selection, and a per-route Access
  review that refuses unprotected routes, `everyone` / bypass policies, routes with no login
  method, zero-seat plans, unpaid subscriptions and binding conflicts. It also covers the
  claim, anonymous external checks of the public hostnames, disconnect and OAuth revocation.
  - The claimed token goes to `/data/.tunnel_token` (0600) and cloudflared starts in token
    mode at once. A failed start rolls back and releases the new binding.
  - On disconnect, the connector is stopped and confirmed gone (process exited, `/ready`
    closed) before the remote binding is released, in the same request. The add-on has to
    wait for a restart instead. Disconnect also clears the local routes, as the add-on does.
  - The device is labelled `Woow Cloudflared (Podman)`. The OAuth client is the add-on's
    (`woow-ha-smart-home`); override it with `PAAS_CLIENT_ID`.
- **Edge-connection status.** `GET /api/health` returns `version`, `tunnel.status`
  (running / starting / stopped), `tunnel.ready_connections`, `stopped_by_operator` and
  `credentials_error`. The status comes from cloudflared's `/ready`, the same signal the
  healthcheck reads. The Dashboard and the nav-bar status dot show it.
- `GET /api/logs`: a snapshot of the buffered cloudflared output.
- `PUT /api/config?restart=true` (Config "Save & Apply") saves the settings and applies them.

**Fixed**
- Restart and "Save & Restart" re-ran the previous cloudflared argv, so saved changes
  (post-quantum, log level, routes) did not take effect. Every start now builds the argv from
  the current settings.
- In local mode, routes edited on the Config page were never written to `config.json`; only
  the wizard did that. A start now regenerates and validates the ingress config from
  `settings.json`. DNS routes are created only for hostnames not routed before, so a start
  does not depend on the Cloudflare API. A host whose ingress lives only in `config.json`
  (no routes in `settings.json`) keeps it untouched.
- `run_parameters` was stored but never passed to cloudflared.
- The log-level list offered `trace`, `notice` and `warning`, which cloudflared rejects at
  start. Only `debug`, `info`, `warn`, `error` and `fatal` remain.
- The token file was written and then chmod'ed. It is now created 0600 atomically.

**Security**
- At startup, at every start and after Cloudflare login or tunnel creation, `cert.pem`,
  `tunnel.json`, `.tunnel_token`, `paas-link.json` and `.csrf_secret` are re-owned and set to
  0600 without reading them. A symlink, a hardlink or a non-regular file blocks the start,
  and the Dashboard shows the reason. These are the add-on 1.1.1 credential-guard rules. The
  process umask is 077.
- 422 responses no longer echo the submitted value. FastAPI's default response returned the
  pasted tunnel token.
- Log lines are redacted before they are buffered or streamed: `--token`, `TunnelSecret`,
  `tunnel_token` and bare `eyJ…` tokens.
- `run_parameters` is limited to the add-on's allow-list (`--edge-bind-address`,
  `--edge-ip-version`, `--grace-period`, `--ha-connections`, `--logfile`, `--loglevel`,
  `--pidfile`, `--protocol`, `--region`, `--retries`, `--tag`). The token, token-file and
  metrics flags cannot be overridden.
- Pasted tokens are normalized: a whole `cloudflared service install eyJ…` command is
  accepted, and a value that is not a tunnel token is refused.

**Behaviour changes and migration**
- `PUT /api/config` `tunnel_token`: omitted or `null` keeps the stored token, `""` removes
  it, and a value replaces it. Token mode without a token is refused with 422. While a PaaS
  link is active, the token and the mode are locked; disconnect on the PaaS page first.
- `run_parameters` is now a list of `--flag=value` strings. The 1.1.0 string form in
  `settings.json` is converted on read, and `--flag value` pairs are joined.
- Stored log levels `trace`, `notice` and `warning` read as `debug`, `info` and `warn`.
- `POST /api/tunnel/start` and `restart` answer 409 with the reason when the tunnel is not
  configured, instead of starting a cloudflared that exits.
- A GUI Stop stays temporary, as in 1.1.0: the healthcheck brings a configured tunnel back
  within about two minutes. A hand-made `/data/.tunnel_stopped` now also stops the boot-time
  autostart, not only the healthcheck, and Start removes it.
- HA-only add-on options have no counterpart here. Use a route for `external_hostname`, and
  a catch-all such as `http://localhost:80` for `nginx_proxy_manager`.

**Shared library**
- The vendored `scripts/lib/quadlet-lib.sh` is now **1.8.0**, not 1.7.0. Two different files
  were released as 1.7.0: the copy vendored here, and the canonical one that had since gained
  `ql_require_healthcheck_timers`, `ql_stop_healthcheck_timer` and an *active*
  `ql_wait_container_healthy` (it runs `podman healthcheck run` itself instead of waiting on
  `.State.Health.Status`, which never moves off `starting` on woowtechopenclaw). That content
  is re-released as 1.8.0; **1.7.0 is withdrawn** and every copy claiming it is now refused.
  The call sites here already passed `QL_HEALTH_ACTIVE=1` explicitly, so the behaviour of this
  package's scripts is unchanged - what changes is that the version string is true again.
- New `scripts/lib/quadlet-lib.versions` (the canonical ledger of released
  `(version, sha256)` pairs) and `tests/lib-version.sh`, which CI now runs. `sha256sum -c` on
  `quadlet-lib.manifest` only ever proved "not edited since it was copied here" - the manifest
  is written by this repo - so it stayed green through the whole collision.

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
