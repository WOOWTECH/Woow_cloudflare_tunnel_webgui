---
name: cf-tunnel-gui-hardening
description: Enterprise-grade testing and hardening of Cloudflare Tunnel Web GUI
status: active
created: 2026-04-07T01:40:09Z
---

# PRD: cf-tunnel-gui-hardening

## Executive Summary

The Cloudflare Tunnel Web GUI for Podman has been deployed and basic smoke testing reveals critical runtime failures. All mutating API endpoints (PUT/POST) crash with 500 errors due to CSRF middleware misconfiguration. SPA routing fails for direct URL access. These issues must be fixed and comprehensively validated before the app can be considered production-ready.

## Problem Statement

After initial deployment at `localhost:8888`, systematic testing uncovered:

1. **P0 — CSRF Middleware Crash**: `starlette-csrf` v3.0.0 `exempt_urls` expects compiled regex patterns, but strings were passed. Every PUT/POST request triggers `AttributeError: 'str' object has no attribute 'match'`, returning 500.
2. **P0 — SPA Fallback Broken**: Vue Router paths (`/config`, `/logs`) return 404 because FastAPI `StaticFiles(html=True)` only serves `index.html` at `/`, not on fallback routes.
3. **P0 — WebSocket Blocked by CSRF**: The `/ws/logs` WebSocket endpoint also crashes through the CSRF middleware stack.
4. **P1 — No End-to-End Token Flow Test**: The full lifecycle (set token → start container → verify running → stream logs → stop) has never been tested.
5. **P1 — Error Responses Not JSON**: When endpoints fail, they return plain text "Internal Server Error" instead of structured JSON error responses.
6. **P2 — Podman API Compatibility**: `podman-py` 5.8.0 `secrets` API may differ from the coded patterns (`.exists()` method may not exist).

## User Stories

### US-1: Operator configures tunnel token
**As** an operator, **I want** to enter my Cloudflare tunnel token in the Config page and save it, **so that** I can start the tunnel.
**Acceptance Criteria:**
- PUT `/api/config` with valid token returns 200 with masked token
- Token is stored as podman secret, never in settings.json
- Invalid token format returns 422 with clear error message
- Missing CSRF token returns 403, not 500

### US-2: Operator starts/stops the tunnel
**As** an operator, **I want** to start, stop, and restart the cloudflared container from the Dashboard, **so that** I can manage the tunnel without SSH.
**Acceptance Criteria:**
- POST `/api/tunnel/start` creates and starts cloudflared container
- POST `/api/tunnel/stop` stops the running container
- POST `/api/tunnel/restart` restarts the container
- Status endpoint reflects real container state after each action
- Actions on non-existent containers return proper 404 JSON

### US-3: Operator views real-time logs
**As** an operator, **I want** to see cloudflared logs in real-time via WebSocket, **so that** I can diagnose tunnel issues.
**Acceptance Criteria:**
- WebSocket `/ws/logs` connects without CSRF interference
- Log lines stream in real-time with timestamps
- Disconnection triggers auto-reconnect in frontend

### US-4: Operator accesses GUI via direct URL
**As** an operator, **I want** to bookmark `https://tunnel-gui.example.com/config` and access it directly, **so that** I can navigate to specific pages without going through the dashboard.
**Acceptance Criteria:**
- All Vue Router routes (`/`, `/config`, `/logs`) return 200 with the SPA index.html
- API routes continue to return JSON, not the SPA

### US-5: System rejects malicious input
**As** a security engineer, **I want** the system to validate all inputs and return structured errors, **so that** injection attacks are blocked and operators see useful error messages.
**Acceptance Criteria:**
- Shell injection in `extra_args` returns 422 with validation error
- Invalid container image returns 400 with clear message
- Path traversal in container name returns 422
- All error responses are JSON with `detail` field

## Functional Requirements

### FR-1: Fix CSRF Middleware
- Replace string `exempt_urls` with compiled `re.Pattern` objects
- Verify CSRF cookie is set on initial GET request
- Verify PUT/POST requests work with valid CSRF token
- Verify PUT/POST without CSRF token return 403

### FR-2: Fix SPA Fallback Routing
- Implement catch-all route or custom middleware that serves `index.html` for non-API, non-static paths
- Ensure API routes (`/api/*`) still return JSON
- Ensure static assets (`/assets/*`, `/favicon.svg`) still serve correctly

### FR-3: End-to-End Tunnel Lifecycle
- Test full flow: set token → start → verify running → stream logs → restart → stop
- Verify podman secret is created/updated correctly
- Verify container is created with correct args and env
- Verify container removal/recreation on config change

### FR-4: Structured Error Responses
- All error responses must be JSON: `{"detail": "message"}`
- HTTP status codes: 400 (bad request), 403 (CSRF), 404 (not found), 422 (validation), 502 (podman error)
- No plain text "Internal Server Error" leaking to clients

### FR-5: Podman API Compatibility
- Verify `podman-py` 5.8.0 API for secrets (exists, create, get, remove)
- Fix any API incompatibilities in `podman_manager.py`
- Handle podman socket connection errors gracefully

## Non-Functional Requirements

- **Availability**: GUI must start and serve within 5 seconds
- **Error Recovery**: WebSocket auto-reconnects within 3 seconds
- **Security**: No raw token exposed in API responses, logs, or config files
- **Compatibility**: Works with Podman 4.x rootless socket

## Success Criteria

1. All 8 API endpoints return correct HTTP status codes (no 500s for expected scenarios)
2. SPA routing works for all 3 pages via direct URL access
3. CSRF protection is functional (403 on missing token, 200 with valid token)
4. Full tunnel lifecycle completes without errors (token → start → logs → stop)
5. All validation rejects malicious input with structured JSON errors
6. WebSocket log streaming connects and receives data
7. Zero regression from fixes (all previously working endpoints still work)

## Constraints & Assumptions

- Podman 4.9.3 is the target runtime (already installed)
- Cloudflare tunnel token `VbABwopRd9lHzUvwCsuFos6eb4bhUKXmcCadtYpr` available for live testing
- No external network dependency for GUI tests (only for cloudflared tunnel connectivity)
- Fixes must be backward-compatible with the existing Dockerfile and docker-compose.yml

## Out of Scope

- Cloudflare API integration (managing ingress rules from GUI)
- Multi-tunnel support
- User authentication (relies on Cloudflare Access)
- UI/UX polish beyond functional correctness
- Performance benchmarking

## Dependencies

- Running Podman daemon with rootless socket
- `cf-tunnel-gui` container deployed at localhost:8888
- Cloudflare tunnel token for end-to-end testing
