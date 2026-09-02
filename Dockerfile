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

# ─── Install Microsoft.Data.Sqlite NuGet packages ───────────────────────────
# PSSQLite's System.Data.SQLite requires SQLite.Interop.dll (Windows-only native
# companion). Microsoft.Data.Sqlite + SQLitePCLRaw works natively on Alpine.
COPY install-sqlite-provider.ps1 /install-sqlite-provider.ps1
RUN ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/install-sqlite-provider.ps1"]
RUN ["rm", "/install-sqlite-provider.ps1"]

# ─── Patch Pode 2.12.1: cache GetNewClosure() to prevent memory leak ────────
# Pode calls ScriptBlock.GetNewClosure() on every timer tick, middleware
# invocation, and route handler call. Each closure creates a SessionState
# snapshot (~5-6 KB) that accumulates at ~3.8 MB/hour because PowerShell's
# internal references prevent GC from collecting them.
#
# Fix: Cache closures so GetNewClosure() is called at most ONCE per unique
# ScriptBlock, not on every invocation. The cache is bounded by the number
# of registered handlers (typically <30 entries).
COPY patches/fix-pode-closures.ps1 /tmp/fix-pode-closures.ps1
RUN ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/tmp/fix-pode-closures.ps1"]
RUN ["rm", "/tmp/fix-pode-closures.ps1"]

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

# ─── .NET GC tuning for long-lived PowerShell container ──────────────────────
# GCConserveMemory=9 (max aggressiveness): GC returns segments to OS sooner,
# compacts more often, and decommits freed pages — the main lever against
# the ~3.4 MB/hr monotonic growth caused by .NET segment retention.
#
# NOTE: Do NOT set DOTNET_GCHeapHardLimit here. Docker ENV is inherited by
# ALL processes in the container, including the Start-Job child pwsh that
# loads ~300 MB of Maester/Pester/Graph/EXO/Teams/Az modules. A 200 MB cap
# causes OOM in the child process, killing it silently and leaving the job
# stuck as "running" until the 30-minute stale timeout.
ENV DOTNET_GCConserveMemory=9

EXPOSE 80

CMD ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/server.ps1"]
