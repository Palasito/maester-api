# syntax=docker/dockerfile:1
# ═══════════════════════════════════════════════════════════════════════════════
# maester-api — PowerShell Core on Alpine Linux
#
# Inspired by https://maester.dev/docs/monitoring/azure-container-app-job
#
# Single-stage build using the official PowerShell Alpine image — ships pwsh,
# no Azure Functions host dependency, no Azurite storage emulator required.
#
# Modules (Pode, Pester, Microsoft.Graph.Authentication, Maester, PSSQLite)
# are baked into the image at build time → zero cold-start download overhead.
#
# Build:  docker build -t maester-api .
# Run:    docker run -p 7071:80 maester-api
# Compose: docker compose up --build
# ═══════════════════════════════════════════════════════════════════════════════

FROM mcr.microsoft.com/powershell:lts-alpine-3.20

# ─── Install native SQLite library ──────────────────────────────────────────
# PSSQLite module needs libsqlite3.so at runtime
RUN apk add --no-cache sqlite-libs

# ─── Pre-install PowerShell modules at build time ────────────────────────────
# The PowerShell Alpine image ships pwsh — exec form bypasses sh entirely.
COPY install-modules.ps1 /install-modules.ps1
RUN ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/install-modules.ps1"]
RUN ["rm", "/install-modules.ps1"]

# ─── Copy application code ──────────────────────────────────────────────────
WORKDIR /app
COPY server.ps1 /app/server.ps1
COPY lib/       /app/lib/

# ─── Security: Run as non-root user ─────────────────────────────────────────
# Create a dedicated unprivileged user for the API server.
# This limits blast radius if the application is compromised.
RUN adduser -D -h /app -s /sbin/nologin maester-api && \
    mkdir -p /app/data && \
    chown -R maester-api:maester-api /app /tmp

# Switch to non-root user
USER maester-api

# Use a dedicated data directory for SQLite (not world-readable /tmp)
ENV MAESTER_DB_PATH=/app/data/maester.db

EXPOSE 80

CMD ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/server.ps1"]
