# Cloudflare Tunnel Web GUI: FastAPI + Vue, with cloudflared as a child process.
# scripts/install.sh builds this as localhost/woow-cf-tunnel:<VERSION>-<git-sha12>
# and the Quadlet unit runs it with Pull=never.

# ── Stage 1: Build Vue frontend ──────────────────────────
FROM node:22-alpine AS frontend-build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm ci --ignore-scripts 2>/dev/null || npm install
COPY frontend/ ./
RUN npm run build

# ── Stage 2: Python runtime ─────────────────────────────
FROM python:3.12-slim
WORKDIR /app

# tini for PID 1 signal handling; curl + ca-certificates to fetch cloudflared
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# --- cloudflared binary (multi-arch), pinned by version AND checksum ---
# The SHA256s are the GitHub release asset digests of this exact version.
# Bump all three together (scripts/upgrade.sh then rebuilds and gates the swap).
ARG TARGETARCH
ARG CLOUDFLARED_VERSION=2026.6.1
ARG CLOUDFLARED_SHA256_AMD64=5861a10a438fe8ddcfebb3b830f83966cbf193edafce0fe2eeb198fbae1f7a22
ARG CLOUDFLARED_SHA256_ARM64=59816ce9b16db71f5bc2a86d59b3632a96c8c3ee934bde2bc8641ee83a6070eb
RUN set -eux; \
    # Cloudflare marked these releases "Do not use; upgrade to 2026.8.2 or later"
    # (path normalisation / trailing-slash stripping for HTTP origins).
    case "$CLOUDFLARED_VERSION" in \
      2026.8.0|2026.8.1) echo "cloudflared $CLOUDFLARED_VERSION is marked 'Do not use' by Cloudflare" >&2; exit 1 ;; \
    esac; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then arch="$(dpkg --print-architecture)"; fi; \
    case "$arch" in \
      amd64) CF_ARCH=amd64; CF_SHA="$CLOUDFLARED_SHA256_AMD64" ;; \
      arm64) CF_ARCH=arm64; CF_SHA="$CLOUDFLARED_SHA256_ARM64" ;; \
      *) echo "unsupported arch ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}"; \
    echo "${CF_SHA}  /usr/local/bin/cloudflared" | sha256sum -c -; \
    chmod +x /usr/local/bin/cloudflared; \
    cloudflared --version

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./backend/

# Copy Vue build output from stage 1
COPY --from=frontend-build /build/dist ./static/

# Liveness probe: backend /api/health AND, when a tunnel is configured,
# cloudflared /ready. The Quadlet unit uses it as HealthCmd=.
COPY scripts/healthcheck.py /usr/local/bin/cf-webui-healthcheck
RUN chmod 0755 /usr/local/bin/cf-webui-healthcheck

ENV PYTHONUNBUFFERED=1
EXPOSE 8000
VOLUME ["/data"]

LABEL org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui" \
      org.opencontainers.image.title="woow-cf-tunnel" \
      org.opencontainers.image.description="Cloudflare Tunnel Web GUI with a supervised cloudflared connector"

# Docker honours HEALTHCHECK; podman builds OCI images and drops it, so the
# Quadlet unit sets HealthCmd= itself.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/cf-webui-healthcheck"]

ENTRYPOINT ["tini", "--"]
# No --host/--port: uvicorn reads UVICORN_HOST / UVICORN_PORT and defaults to
# 127.0.0.1:8000, so the image is loopback-only unless told otherwise. The
# Quadlet unit pins UVICORN_HOST=127.0.0.1 and renders UVICORN_PORT.
CMD ["uvicorn", "backend.main:app"]
