---
name: cf-tunnel-gui-hardening
status: in-progress
created: 2026-04-07T01:40:09Z
updated: 2026-04-07T01:40:09Z
progress: 0%
prd: .claude/prds/cf-tunnel-gui-hardening.md
github: (will be set on sync)
---

# Epic: cf-tunnel-gui-hardening

## Overview

Fix all critical runtime failures in the Cloudflare Tunnel Web GUI and validate end-to-end functionality to enterprise deployment quality. Three P0 bugs (CSRF crash, SPA routing, WebSocket blocked) prevent all write operations and page navigation.

## Architecture Decisions

- Replace `starlette-csrf` string-based `exempt_urls` with compiled regex patterns
- Replace `StaticFiles(html=True)` mount with a catch-all FastAPI route for SPA fallback
- Ensure API routes are registered BEFORE the SPA catch-all
- Fix `podman_manager.py` to use the actual `podman-py` 5.8.0 API

## Technical Approach

### Backend Fixes (main.py, podman_manager.py)
1. Fix CSRF middleware `exempt_urls` to use `re.compile()` patterns
2. Add SPA catch-all route as a FastAPI endpoint (not StaticFiles mount)
3. Fix podman-py secret API calls to match v5.8.0 interface
4. Add global exception handler for structured JSON error responses

### Validation Testing
1. Automated curl-based API test script covering all endpoints
2. E2E tunnel lifecycle test with real Cloudflare token
3. Security validation (CSRF, injection, path traversal)

## Task Breakdown Preview

1. Fix CSRF middleware configuration (P0)
2. Fix SPA fallback routing (P0)
3. Fix podman-py API compatibility (P0/P1)
4. Add global error handler for structured JSON responses (P1)
5. End-to-end tunnel lifecycle test (P1)
6. Rebuild, redeploy, and run full validation suite

## Dependencies

- Tasks 1-4 can run in parallel (different files)
- Task 5 depends on tasks 1-4 being complete
- Task 6 depends on all previous tasks

## Success Criteria (Technical)

- `curl` test suite: 0 unexpected 500 errors
- All 3 SPA routes return 200 with HTML
- CSRF: 403 without token, 200 with valid token
- Full lifecycle: token → start → status=running → logs stream → stop → status=exited

## Estimated Effort

~2 hours total: 1 hour fixes, 1 hour testing/validation
