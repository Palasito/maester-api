# Pode API Architecture Design — Maester Docker Backend

> **Status:** Approved — All open questions resolved  
> **Author:** AI Agent  
> **Date:** 2025-07-15 (Updated: 2025-07-15)  
> **Audience:** Implementation reference

---

## Table of Contents

1. [Overview & Goals](#1-overview--goals)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Docker Infrastructure](#3-docker-infrastructure)
4. [SQLite Schema & Data Layer](#4-sqlite-schema--data-layer)
5. [API Contract](#5-api-contract)
6. [Authentication Flow](#6-authentication-flow)
7. [Background Execution](#7-background-execution)
8. [Cleanup & Garbage Collection](#8-cleanup--garbage-collection)
9. [PipePal Frontend Integration](#9-pipepal-frontend-integration)
10. [File Structure](#10-file-structure)
11. [Implementation Phases](#11-implementation-phases)
12. [Security Considerations](#12-security-considerations)
13. [Open Questions](#13-open-questions)

---

## 1. Overview & Goals

### What
A self-contained Docker container running PowerShell Core on Alpine Linux, exposing a Pode HTTP API that:
1. Accepts Maester test run requests from PipePal
2. Authenticates to Microsoft Graph, Exchange Online, and Microsoft Teams using a delegated bearer token
3. Executes Maester test suites asynchronously via `Start-ThreadJob`
4. Tracks job state in SQLite (replacing JSON file persistence)
5. Returns structured test results when polled

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Ephemeral storage** | SQLite DB lives at `/tmp/maester.db` — lost on container restart. No persistent volume required. Completed results auto-expire after 2 hours. |
| **Lightweight** | Single Alpine image (~150MB), single PowerShell process, no sidecar services, no Azure Functions host, no storage emulator. |
| **Backward-compatible** | Identical API contract to the current Azure Functions backend — PipePal proxy requires zero code changes. |
| **Single bearer token** | Phase 1: One Graph token from PipePal authenticates Graph (Maester core). Phase 3: Multi-token strategy — separate Exchange/Teams tokens via additional headers. Services that fail to connect are silently skipped. |
| **Thread-safe** | SQLite WAL mode allows concurrent reads from Pode HTTP threads while a single thread job writes results. |

### What Changes vs. Current `server.ps1`

| Area | Current (JSON files) | Proposed (SQLite) |
|------|---------------------|-------------------|
| Job state storage | One `.json` file per job in `/home/maester-jobs/` | Single SQLite DB at `/tmp/maester.db` |
| Atomic writes | Temp file → rename | SQLite transactions (ACID) |
| Concurrency | File locking (potential race conditions) | SQLite WAL mode (designed for concurrent access) |
| Cleanup | Iterate directory, check file dates | `DELETE FROM jobs WHERE ...` (fast, indexed) |
| Auth services | Graph only | Graph + Exchange Online + Teams (graceful fallback) |
| Docker volume | Required (`maester-jobs:/home/maester-jobs`) | Optional (remove for full ephemeral, or mount `/data` for persistence) |
| Query capability | Read individual file by jobId only | SQL queries: list jobs, filter by status, aggregate stats |

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PipePal (Browser)                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  MaesterContent.tsx                                               │   │
│  │  └─ useMaesterTests.ts (React Query useMutation)                  │   │
│  │     └─ maesterService.ts → fetch('/api/proxy-maester', ...)       │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
            POST (start) / GET (poll)
            Authorization: Bearer <graphToken>
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PipePal Next.js API Route (proxy-maester.ts)                            │
│  - Adds x-functions-key (or future: API key header)                      │
│  - Forwards Authorization + body verbatim                                │
│  - Returns upstream JSON/status code                                     │
└──────────────────────┬───────────────────────────────────────────────────┘
                       │
          HTTP (host:7071 → container:80)
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Docker Container (Alpine + pwsh + Pode)                                 │
│                                                                          │
│  ┌───────── Pode HTTP Server (4 threads) ──────────────────────────┐   │
│  │                                                                   │   │
│  │  GET /health            → { status: "ok" }                        │   │
│  │  POST /api/MaesterRunner → validate auth → insert job → 202      │   │
│  │  GET /api/MaesterRunner  → query SQLite → return job state        │   │
│  │                                                                   │   │
│  │  Middleware: API key validation (X-Api-Key header)                 │   │
│  │  Scheduled Timer: cleanup expired jobs every 15 min               │   │
│  └──────────────┬────────────────────────────────────────────────────┘   │
│                 │                                                         │
│      Start-ThreadJob (fire-and-forget)                                   │
│                 │                                                         │
│                 ▼                                                         │
│  ┌───────── Background Thread ──────────────────────────────────────┐   │
│  │                                                                   │   │
│  │  1. Import modules (Graph, Exchange, Teams, Maester, Pester)      │   │
│  │  2. Connect-MgGraph -AccessToken $graphToken (REQUIRED)           │   │
│  │  3. Connect-ExchangeOnline -AccessToken $exoToken (Phase 3)       │   │
│  │  4. Connect-MicrosoftTeams -AccessTokens @($graph,$teams) (Ph 3)  │   │
│  │  5. Resolve test paths for selected suites                        │   │
│  │  6. Build Pester configuration (tags, severity, exclusions)       │   │
│  │  7. Invoke-Maester → results.json                                 │   │
│  │  8. Transform results → PipePal format                            │   │
│  │  9. UPDATE jobs SET status='completed', result=<json>             │   │
│  │  10. Disconnect all services + cleanup temp dir                   │   │
│  │                                                                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌───────── SQLite (/tmp/maester.db) ───────────────────────────────┐   │
│  │  WAL mode, busy_timeout 5000ms                                    │   │
│  │  Table: jobs (job_id, status, created_at, updated_at, ...)        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Docker Infrastructure

### 3.1 Dockerfile Changes

```dockerfile
# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/powershell:lts-alpine-3.20

# ─── Install native SQLite library ──────────────────────────────
# PSSQLite module needs libsqlite3.so at runtime
RUN apk add --no-cache sqlite-libs

# ─── Pre-install PowerShell modules ─────────────────────────────
COPY install-modules.ps1 /install-modules.ps1
RUN ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/install-modules.ps1"]
RUN ["rm", "/install-modules.ps1"]

# ─── Copy application ──────────────────────────────────────────
WORKDIR /app
COPY server.ps1    /app/server.ps1
COPY lib/          /app/lib/

EXPOSE 80
CMD ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/server.ps1"]
```

**Changes from current:**
- Added `apk add --no-cache sqlite-libs` for native SQLite
- Added `COPY lib/ /app/lib/` for modularized helper scripts
- Removed: no changes to base image or module install pattern

### 3.2 Module Additions (`install-modules.ps1`)

Add `PSSQLite` to the module list:

```powershell
$modules = @(
    'Pode'
    'Microsoft.PowerShell.ThreadJob'
    'Pester'
    'Microsoft.Graph.Authentication'
    'ExchangeOnlineManagement'
    'MicrosoftTeams'
    'PSSQLite'                          # ← NEW: SQLite access
    'Maester'
)
```

**PSSQLite** provides `Invoke-SqliteQuery` — a clean PowerShell-native interface to SQLite. It wraps `System.Data.SQLite` and handles connection pooling, parameterized queries, and type mapping.

### 3.3 docker-compose.yml

```yaml
services:
  maester-api:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "7071:80"
    environment:
      # API key for proxy authentication (matches PipePal's x-functions-key)
      - MAESTER_API_KEY=${MAESTER_API_KEY:-local-dev-key}
      # Optional: mount a volume for SQLite persistence across restarts
      # - MAESTER_DB_PATH=/data/maester.db
    # volumes:
    #   - maester-data:/data     # Uncomment for persistent DB across restarts
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "pwsh", "-NonInteractive", "-Command",
             "try { Invoke-RestMethod http://localhost:80/health | Out-Null; exit 0 } catch { exit 1 }"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

# volumes:
#   maester-data:                # Uncomment if persistence is desired
```

**Key changes:**
- Volume is **commented out by default** (ephemeral storage per design principle)
- Environment variable `MAESTER_API_KEY` replaces `x-functions-key` authentication
- Optional `MAESTER_DB_PATH` override for persistent storage scenarios

### 3.4 Estimated Image Size

| Layer | Approximate Size |
|-------|-----------------|
| Base Alpine PowerShell | ~87 MB |
| `sqlite-libs` | ~1.2 MB |
| PowerShell modules (8 total) | ~60 MB |
| Application code | <50 KB |
| **Total** | **~150 MB** |

---

## 4. SQLite Schema & Data Layer

### 4.1 Database Initialization

On server startup, `server.ps1` creates the DB and table if they don't exist:

```powershell
$DB_PATH = if ($env:MAESTER_DB_PATH) { $env:MAESTER_DB_PATH } else { '/tmp/maester.db' }

# Create DB + table (idempotent)
Invoke-SqliteQuery -DataSource $DB_PATH -Query @"
    CREATE TABLE IF NOT EXISTS jobs (
        job_id       TEXT    PRIMARY KEY,
        status       TEXT    NOT NULL DEFAULT 'running',
        created_at   TEXT    NOT NULL,
        updated_at   TEXT    NOT NULL,
        suites       TEXT,          -- JSON array, e.g. '["maester","eidsca"]'
        severity     TEXT,          -- JSON array, e.g. '["Critical","High"]'
        result       TEXT,          -- Full PipePal JSON result (can be large)
        error        TEXT,          -- Error message on failure
        duration_ms  INTEGER        -- Total runtime in milliseconds
    );
"@

# Enable WAL mode for concurrent reads + single writer
Invoke-SqliteQuery -DataSource $DB_PATH -Query "PRAGMA journal_mode=WAL;"
Invoke-SqliteQuery -DataSource $DB_PATH -Query "PRAGMA busy_timeout=5000;"
```

### 4.2 Schema Rationale

| Column | Type | Purpose |
|--------|------|---------|
| `job_id` | TEXT PK | 32-char hex GUID (matches current `[guid]::NewGuid().ToString('N')`) |
| `status` | TEXT | `running` → `completed` or `failed` |
| `created_at` | TEXT | ISO 8601 UTC timestamp |
| `updated_at` | TEXT | ISO 8601 UTC, updated on every state change |
| `suites` | TEXT | JSON array of requested suite names (for display/filtering) |
| `severity` | TEXT | JSON array of severity filters (for display/filtering) |
| `result` | TEXT | Full PipePal-format JSON (`{totalCount, passedCount, ..., tests:[...]}`) |
| `error` | TEXT | Error message when `status='failed'` |
| `duration_ms` | INTEGER | Total test execution time |

**Why store `result` as TEXT in SQLite?**
- SQLite handles TEXT columns up to 1 GB — Maester results are typically 50-500 KB
- Avoids a separate file system for results
- Single source of truth: `SELECT result FROM jobs WHERE job_id = ?`
- Cleanup is one `DELETE` statement — no orphaned files
- Trade-off: slightly larger DB file, but ephemeral so no long-term concern

### 4.3 Data Access Helper Module (`lib/db.ps1`)

A reusable script that exports functions for all DB operations. Loaded by `server.ps1` at startup and available to all routes and the thread job scriptblock.

```powershell
# lib/db.ps1 — SQLite data access helpers

function Initialize-MaesterDb {
    param([string]$DbPath)
    # CREATE TABLE IF NOT EXISTS + PRAGMA WAL + busy_timeout
}

function New-MaesterJob {
    param([string]$DbPath, [string]$JobId, [string[]]$Suites, [string[]]$Severity)
    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        INSERT INTO jobs (job_id, status, created_at, updated_at, suites, severity)
        VALUES (@jobId, 'running', @now, @now, @suites, @severity)
    "@ -SqlParameters @{
        jobId    = $JobId
        now      = $now
        suites   = ($Suites | ConvertTo-Json -Compress)
        severity = ($Severity | ConvertTo-Json -Compress)
    }
}

function Get-MaesterJob {
    param([string]$DbPath, [string]$JobId)
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        SELECT * FROM jobs WHERE job_id = @jobId
    "@ -SqlParameters @{ jobId = $JobId }
}

function Update-MaesterJob {
    param(
        [string]$DbPath,
        [string]$JobId,
        [string]$Status,
        [string]$Result,    # JSON string
        [string]$Error,
        [int]$DurationMs
    )
    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        UPDATE jobs
        SET status     = @status,
            updated_at = @now,
            result     = @result,
            error      = @error,
            duration_ms = @durationMs
        WHERE job_id   = @jobId
    "@ -SqlParameters @{
        jobId      = $JobId
        status     = $Status
        now        = $now
        result     = $Result
        error      = $Error
        durationMs = $DurationMs
    }
}

function Remove-MaesterJob {
    param([string]$DbPath, [string]$JobId)
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs WHERE job_id = @jobId
    "@ -SqlParameters @{ jobId = $JobId }
}

function Remove-ExpiredJobs {
    param([string]$DbPath, [int]$MaxAgeHours = 2, [int]$CompletedTimeoutMinutes = 10)
    $hardCutoff      = [datetime]::UtcNow.AddHours(-$MaxAgeHours).ToString('o')
    $completedCutoff = [datetime]::UtcNow.AddMinutes(-$CompletedTimeoutMinutes).ToString('o')

    # Hard: delete anything older than MaxAgeHours
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs WHERE created_at < @cutoff
    "@ -SqlParameters @{ cutoff = $hardCutoff }

    # Soft: delete completed/failed jobs older than CompletedTimeoutMinutes
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs
        WHERE status IN ('completed', 'failed')
          AND updated_at < @cutoff
    "@ -SqlParameters @{ cutoff = $completedCutoff }
}

function Get-StaleRunningJobs {
    param([string]$DbPath, [int]$StaleMinutes = 30)
    $cutoff = [datetime]::UtcNow.AddMinutes(-$StaleMinutes).ToString('o')
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        SELECT job_id FROM jobs
        WHERE status = 'running'
          AND created_at < @cutoff
    "@ -SqlParameters @{ cutoff = $cutoff }
}

function Set-JobTimedOut {
    param([string]$DbPath, [string]$JobId, [int]$ElapsedMinutes)
    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        UPDATE jobs
        SET status     = 'failed',
            error      = @error,
            updated_at = @now
        WHERE job_id   = @jobId AND status = 'running'
    "@ -SqlParameters @{
        jobId = $JobId
        error = "Job timed out after $ElapsedMinutes minutes. The container may have restarted."
        now   = $now
    }
}
```

### 4.4 Thread Safety

SQLite with WAL (Write-Ahead Logging) mode provides:
- **Multiple concurrent readers** — Pode's 4 HTTP threads can all query jobs simultaneously
- **Single writer** — `Start-ThreadJob` writes are serialized by SQLite's internal lock
- **Non-blocking reads during writes** — Readers don't block when the thread job writes results
- **`busy_timeout=5000`** — If a write lock is held, wait up to 5 seconds before failing (prevents `SQLITE_BUSY` errors)

PSSQLite opens and closes connections per `Invoke-SqliteQuery` call by default, which is correct for this workload — no long-lived connections to manage.

### 4.5 Why Not In-Memory SQLite?

In-memory (`":memory:"`) would be faster but:
- ❌ Each `Invoke-SqliteQuery` call with `":memory:"` creates a *separate* in-memory DB
- ❌ Thread jobs can't share an in-memory DB with Pode threads
- ✅ File-based `/tmp/maester.db` is shared across all threads + processes
- ✅ Still ephemeral — `/tmp/` is cleared on container restart

---

## 5. API Contract

### 5.1 Overview

All routes are backward-compatible with the current Azure Functions API. PipePal's `proxy-maester.ts` requires **zero changes**.

| Method | Path | Description | Auth |
|--------|------|-------------|------|
| `GET` | `/health` | Container health check | None |
| `POST` | `/api/MaesterRunner` | Start a new test run | API Key + Bearer |
| `GET` | `/api/MaesterRunner?jobId=<id>` | Poll job status/results | API Key |

### 5.2 Authentication Middleware

**API Key Validation** (replaces Azure Function `x-functions-key`):

```
Pode Middleware → Check X-Functions-Key or X-Api-Key header
  ├─ Missing/invalid → 401 Unauthorized
  └─ Valid → proceed to route handler
```

The middleware reads `$env:MAESTER_API_KEY` and validates against the request header. This gives PipePal's existing `x-functions-key` header seamless compatibility.

**Bearer Token** (per-request, POST only):
- Extracted from `Authorization: Bearer <token>` header
- Passed to the background thread job as an argument
- Used inside the thread to connect Graph / Exchange / Teams
- Never stored in SQLite (security)

### 5.3 POST /api/MaesterRunner — Start Test Run

**Request:**
```http
POST /api/MaesterRunner HTTP/1.1
Authorization: Bearer <graphToken>
X-Functions-Key: <apiKey>
Content-Type: application/json

{
    "suites": ["maester", "eidsca"],         // Optional. Default: all 5 suites
    "severity": ["Critical", "High"],         // Optional. Default: all severities
    "tags": ["MS.AAD.1.1"],                   // Optional. Extra Pester tag filters
    "includeLongRunning": false,              // Optional. Default: false
    "includePreview": false                   // Optional. Default: false
}
```

**Response (202 Accepted):**
```json
{
    "jobId": "a1b2c3d4e5f6789012345678abcdef01",
    "status": "running",
    "createdAt": "2025-07-15T10:30:00.0000000Z"
}
```

**Processing Flow:**
```
1. Validate API key (middleware)
2. Extract Bearer token from Authorization header
3. Parse request body (suites, severity, tags, etc.)
4. Generate jobId = [guid]::NewGuid().ToString('N')
5. INSERT INTO jobs (job_id, status, created_at, ...) → 'running'
6. Cleanup: DELETE expired jobs from SQLite
7. Cleanup: Remove completed ThreadJobs from PowerShell job table
8. Start-ThreadJob with all parameters
9. Return 202 { jobId, status, createdAt }
```

### 5.4 GET /api/MaesterRunner — Poll Job Status

**Request:**
```http
GET /api/MaesterRunner?jobId=a1b2c3d4e5f6789012345678abcdef01 HTTP/1.1
X-Functions-Key: <apiKey>
```

**Response (200 OK) — Running:**
```json
{
    "jobId": "a1b2c3d4e5f6789012345678abcdef01",
    "status": "running",
    "createdAt": "2025-07-15T10:30:00.0000000Z",
    "updatedAt": "2025-07-15T10:30:00.0000000Z",
    "result": null,
    "error": null
}
```

**Response (200 OK) — Completed:**
```json
{
    "jobId": "a1b2c3d4e5f6789012345678abcdef01",
    "status": "completed",
    "createdAt": "2025-07-15T10:30:00.0000000Z",
    "updatedAt": "2025-07-15T10:35:12.0000000Z",
    "result": {
        "totalCount": 147,
        "passedCount": 120,
        "failedCount": 15,
        "skippedCount": 12,
        "durationMs": 312450,
        "timestamp": "2025-07-15T10:30:00.0000000Z",
        "suitesRun": ["maester", "eidsca"],
        "severityFilter": ["Critical", "High"],
        "tests": [
            {
                "id": "EIDSCA.AP01",
                "name": "Default Authorization Policy - Allowed to create Apps",
                "result": "Passed",
                "duration": 234,
                "severity": "High",
                "category": "EIDSCA",
                "block": "EIDSCA.AP01 Default Authorization Policy",
                "errorRecord": null
            }
        ]
    },
    "error": null
}
```

**Response (200 OK) — Failed:**
```json
{
    "jobId": "a1b2c3d4e5f6789012345678abcdef01",
    "status": "failed",
    "createdAt": "2025-07-15T10:30:00.0000000Z",
    "updatedAt": "2025-07-15T10:31:05.0000000Z",
    "result": null,
    "error": "Connect-MgGraph failed: token expired or invalid."
}
```

**Response (404 Not Found):**
```json
{ "error": "Job not found: a1b2c3d4e5f6789012345678abcdef01" }
```

**Processing Flow:**
```
1. Validate API key (middleware)
2. Extract jobId from query string
3. SELECT * FROM jobs WHERE job_id = ?
4. If not found → 404
5. If status = 'running' → check stale timeout
   └─ If stale → UPDATE status='failed', error='Job timed out...'
6. Return job data as JSON
7. If terminal state → DELETE FROM jobs WHERE job_id = ?
   (caller has the data now, no need to keep it)
```

**Important behavior: Terminal state cleanup.**
When a GET returns a completed or failed job, the row is deleted from SQLite immediately afterward. This ensures:
- No accumulation of stale data
- The frontend can't accidentally re-fetch old results
- SQLite stays small without needing periodic VACUUM

### 5.5 GET /health — Health Check

**Response (200 OK):**
```json
{
    "status": "ok",
    "uptime": 3600,
    "dbConnected": true,
    "activeJobs": 1
}
```

Enhanced from the current simple `{"status":"ok"}` to aid debugging. Remains backward-compatible (still returns `status: "ok"` at minimum).

### 5.6 Error Responses

All error responses follow a consistent format:

```json
{
    "error": "Human-readable error message"
}
```

| Status | Meaning |
|--------|---------|
| `400` | Bad request (missing jobId, malformed body) |
| `401` | Missing or invalid API key or Bearer token |
| `404` | Job not found |
| `405` | Method not allowed |
| `500` | Internal server error (catch-all) |
| `202` | Job started (POST only) |
| `200` | Job status returned (GET) |

---

## 6. Authentication Flow

### 6.1 Two-Layer Auth

```
Layer 1: API Key (all routes except /health)
  └─ Header: X-Functions-Key  (or X-Api-Key — both accepted)
  └─ Compared against $env:MAESTER_API_KEY
  └─ Purpose: Prevent unauthorized access to the container

Layer 2: Bearer Token (POST /api/MaesterRunner only)
  └─ Header: Authorization: Bearer <token>
  └─ Purpose: Authenticate to Microsoft services on behalf of customer tenant
  └─ Passed to ThreadJob as argument, NEVER stored in DB
```

### 6.2 Multi-Service Authentication — Research Findings

> **Research conducted:** 2025-07-15 via Microsoft Learn official documentation.

Microsoft's OAuth system issues **resource-specific tokens**. A token issued for one audience (resource) **cannot** authenticate to a different audience. This is a fundamental OAuth 2.0 constraint enforced by Azure AD / Entra ID.

#### Token Audience Requirements (Verified)

| Service | Audience / Resource | Token Parameter | Documentation |
|---------|--------------------|-----------------|---------| 
| **Microsoft Graph** | `https://graph.microsoft.com` | `Connect-MgGraph -AccessToken <SecureString>` | [Connect-MgGraph docs](https://learn.microsoft.com/powershell/module/microsoft.graph.authentication/connect-mggraph) |
| **Exchange Online** | `https://outlook.office365.com` | `Connect-ExchangeOnline -AccessToken <String>` (v3.1.0+) | [Connect-ExchangeOnline docs](https://learn.microsoft.com/powershell/module/exchangepowershell/connect-exchangeonline) |
| **Microsoft Teams** | `https://graph.microsoft.com` + `48ac35b8-9aa8-4d74-927d-1f4a14a0b239` (Skype & Teams Tenant Admin API) | `Connect-MicrosoftTeams -AccessTokens @($GraphToken, $TeamsToken)` | [Connect-MicrosoftTeams docs](https://learn.microsoft.com/powershell/module/microsoftteams/connect-microsoftteams) |

#### Key Findings

**Exchange Online:**
- `Connect-ExchangeOnline -AccessToken` accepts a raw JWT string (not SecureString)
- The token **must** have audience `https://outlook.office365.com/.default` — a Graph-audience token will be rejected
- When using `-AccessToken`, you also need `-Organization` (app-only) or `-DelegatedOrganization` (delegated) or `-UserPrincipalName` (delegated)
- Available in ExchangeOnlineManagement module **v3.1.0-Preview1+** (we have v3.9.2 ✅)

**Microsoft Teams:**
- `-AccessTokens` requires an **array of TWO tokens**: `@($GraphToken, $TeamsToken)`
- The first token must have Graph audience: `https://graph.microsoft.com/.default`
- The second token must have Teams Admin API audience: `48ac35b8-9aa8-4d74-927d-1f4a14a0b239/.default`
- Both delegated and app-only flows are supported (v4.7.1+ for app-based)
- Delegated flow requires permissions: `User.Read.All`, `Group.ReadWrite.All`, `TeamSettings.ReadWrite.All`, etc. + `user_impersonation` on Teams Admin API

**Conclusion: A single Graph bearer token CANNOT authenticate Exchange or Teams.**

#### Multi-Token Architecture (Recommended for Future Phases)

When Exchange/Teams support is needed, PipePal will acquire per-audience tokens using MSAL's `acquireTokenSilent()` and send them as separate headers:

```
PipePal Browser → proxy-maester.ts → Docker Container

Headers:
  Authorization: Bearer <graph-token>          ← audience: graph.microsoft.com
  X-Exchange-Token: <exchange-token>            ← audience: outlook.office365.com
  X-Teams-Token: <teams-admin-token>            ← audience: 48ac35b8-...
```

**PipePal MSAL Token Acquisition (Future):**
```typescript
// Each audience requires a separate acquireTokenSilent call
const graphToken = await msalInstance.acquireTokenSilent({
    scopes: ['https://graph.microsoft.com/.default'],
    account: activeAccount,
});

const exchangeToken = await msalInstance.acquireTokenSilent({
    scopes: ['https://outlook.office365.com/.default'],
    account: activeAccount,
});

const teamsToken = await msalInstance.acquireTokenSilent({
    scopes: ['48ac35b8-9aa8-4d74-927d-1f4a14a0b239/.default'],
    account: activeAccount,
});
```

**Thread Job (Future Multi-Token):**
```powershell
# ── Phase 1: Microsoft Graph (REQUIRED) ──────────────────────────
$secureToken = ConvertTo-SecureString -String $GraphToken -AsPlainText -Force
Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

# ── Phase 2: Exchange Online (OPTIONAL) ──────────────────────────
$exoConnected = $false
if ($ExchangeToken) {
    try {
        Connect-ExchangeOnline -AccessToken $ExchangeToken `
            -Organization $TenantDomain -ShowBanner:$false -ErrorAction Stop
        $exoConnected = $true
    } catch {
        Write-Warning "Exchange Online: skipped ($($_.Exception.Message))"
    }
}

# ── Phase 3: Microsoft Teams (OPTIONAL) ──────────────────────────
$teamsConnected = $false
if ($TeamsToken) {
    try {
        Connect-MicrosoftTeams -AccessTokens @($GraphToken, $TeamsToken) -ErrorAction Stop
        $teamsConnected = $true
    } catch {
        Write-Warning "Microsoft Teams: skipped ($($_.Exception.Message))"
    }
}
```

**Key design decisions:**
- Graph is **REQUIRED** — job fails if Graph connection fails
- Exchange/Teams are **OPTIONAL** — skipped silently if token not provided or connection fails
- ORCA/Teams-specific tests show as "Skipped" or "NotRun" when service unavailable
- The result includes a `connections` field showing which services were active

### 6.3 Token Scope Requirements

| Service | Token Audience | Key Delegated Permissions | Used By |
|---------|---------------|--------------------------|--------|
| **Microsoft Graph** | `https://graph.microsoft.com` | `Directory.Read.All`, `Policy.Read.All`, `Reports.Read.All` | All suites (core) |
| **Exchange Online** | `https://outlook.office365.com` | `Exchange.ManageAsApp` or EXO-specific permissions | ORCA suite |
| **Microsoft Teams** | `48ac35b8-9aa8-4d74-927d-1f4a14a0b239` | `user_impersonation` (Skype & Teams Tenant Admin API) | CIS/CISA Teams tests |

**Phase 1 (current):** Graph-only. PipePal sends a single Graph token. Exchange/Teams are not connected.

**Phase 3 (future):** Multi-token. PipePal acquires and sends per-audience tokens. Backend reads from separate headers.

### 6.4 Phase 1 Authentication (Graph-Only)

For the initial implementation, only Graph is supported:

```powershell
# Phase 1: Graph Only (current)
$secureToken = ConvertTo-SecureString -String $RawToken -AsPlainText -Force
Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
```

Exchange/Teams tokens will be accepted via optional headers when Phase 3 is implemented. The auth layer (`lib/auth.ps1`) is designed to extract all three tokens, returning `$null` for any not provided:

```powershell
function Get-ServiceTokens {
    param($Headers)
    return @{
        Graph    = Get-BearerToken -Headers $Headers      # Required
        Exchange = $Headers['X-Exchange-Token']            # Optional (Phase 3)
        Teams    = $Headers['X-Teams-Token']               # Optional (Phase 3)
    }
}
```

---

## 7. Background Execution

### 7.1 Thread Job Pattern

Identical to current pattern — `Start-ThreadJob` creates a .NET thread within the Pode process:

```
POST handler (Pode HTTP thread)
  │
  ├─ 1. Validate + parse request
  ├─ 2. INSERT INTO jobs → 'running'
  ├─ 3. Start-ThreadJob -Name "maester-$jobId" -ArgumentList @(...)
  │     └─ Returns immediately (non-blocking)
  └─ 4. Return HTTP 202 { jobId, status, createdAt }

Background thread (fires independently)
  │
  ├─ 1. Import modules
  ├─ 2. Connect services (Graph + optional Exchange/Teams)
  ├─ 3. Resolve test paths + build Pester config
  ├─ 4. Invoke-Maester (this takes 2-8 minutes)
  ├─ 5. Transform results to PipePal format
  ├─ 6. UPDATE jobs SET status='completed', result=<json>
  └─ 7. Cleanup: disconnect services, delete temp dir
```

### 7.2 Thread Job Arguments

The thread job receives everything it needs as arguments (thread jobs don't share Pode's runspace variables):

```powershell
$null = Start-ThreadJob -Name "maester-$jobId" -ArgumentList @(
    $rawToken,         # [string]   Bearer token
    $suites,           # [string[]] Suite names
    $severities,       # [string[]] Severity filters
    $extraTags,        # [string[]] Additional Pester tags
    $incLongRunning,   # [bool]     Include LongRunning-tagged tests
    $incPreview,       # [bool]     Include Preview-tagged tests
    $jobId,            # [string]   Job ID for DB updates
    $DB_PATH           # [string]   SQLite DB path (for updates)
) -ScriptBlock { ... }
```

### 7.3 SQLite Updates from Thread Job

Inside the thread job, the `PSSQLite` module is imported and used directly:

```powershell
# Inside the thread job scriptblock:
Import-Module -Name PSSQLite -ErrorAction Stop

function Update-JobInDb {
    param($DbPath, $JobId, $Status, $Result, $Error, $DurationMs)
    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        UPDATE jobs SET status=@s, updated_at=@u, result=@r, error=@e, duration_ms=@d
        WHERE job_id=@j
    "@ -SqlParameters @{
        j = $JobId; s = $Status; u = $now
        r = $Result; e = $Error; d = $DurationMs
    }
}

try {
    # ... run Maester tests ...
    $resultJson = $summary | ConvertTo-Json -Depth 12 -Compress
    Update-JobInDb -DbPath $DbPath -JobId $JobId -Status 'completed' `
                   -Result $resultJson -Error $null -DurationMs $durationMs
} catch {
    Update-JobInDb -DbPath $DbPath -JobId $JobId -Status 'failed' `
                   -Result $null -Error $_.Exception.Message -DurationMs 0
}
```

### 7.4 Concurrency Limits

**Decision: Maximum 5 concurrent jobs.**

Maester test runs are resource-intensive (CPU, memory, network), but real-world usage requires supporting multiple concurrent tenant scans. Five concurrent jobs balances usability with resource constraints.

Implementation:

```powershell
$MAX_CONCURRENT_JOBS = 5

# Before starting a new job, check for running jobs
$runningCount = (Invoke-SqliteQuery -DataSource $DB_PATH -Query @"
    SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'
"@).cnt

if ($runningCount -ge $MAX_CONCURRENT_JOBS) {
    Set-PodeResponseStatus -Code 409   # Conflict
    Write-PodeJsonResponse -Value @{
        error = "Maximum concurrent job limit reached ($MAX_CONCURRENT_JOBS). Please wait for a running job to complete."
    }
    return
}
```

The limit is configurable via a constant at the top of `server.ps1`. If the container has limited resources, reduce to 1-2.

---

## 8. Cleanup & Garbage Collection

### 8.1 Cleanup Strategy

Three cleanup mechanisms work together:

| Mechanism | Trigger | What it does |
|-----------|---------|-------------|
| **On-poll cleanup** | Every `GET` that returns a terminal state | `DELETE FROM jobs WHERE job_id = ?` — immediate |
| **On-POST cleanup** | Every `POST` before starting a new job | `DELETE FROM jobs WHERE created_at < 2h ago` and `DELETE completed/failed WHERE updated_at < 10min ago` |
| **Scheduled timer** | Pode timer, every 15 minutes | Same as on-POST + `VACUUM` + stale job detection |

### 8.2 Pode Scheduled Timer

```powershell
# Inside Start-PodeServer { ... }
Add-PodeTimer -Name 'JobCleanup' -Interval 900 -ScriptBlock {
    $dbPath       = $using:DB_PATH
    $staleMinutes = $using:JOB_STALE_MINUTES

    Import-Module PSSQLite -ErrorAction SilentlyContinue

    # 1. Mark stale running jobs as failed
    $cutoff = [datetime]::UtcNow.AddMinutes(-$staleMinutes).ToString('o')
    $now    = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $dbPath -Query @"
        UPDATE jobs
        SET status = 'failed',
            error = 'Job timed out (cleanup timer). Container may have restarted.',
            updated_at = @now
        WHERE status = 'running' AND created_at < @cutoff
    "@ -SqlParameters @{ cutoff = $cutoff; now = $now }

    # 2. Delete expired jobs
    $hardCutoff = [datetime]::UtcNow.AddHours(-2).ToString('o')
    Invoke-SqliteQuery -DataSource $dbPath -Query @"
        DELETE FROM jobs WHERE created_at < @cutoff
    "@ -SqlParameters @{ cutoff = $hardCutoff }

    # 3. Cleanup completed ThreadJobs from PowerShell job table
    Get-Job | Where-Object { $_.State -in @('Completed', 'Failed') } |
        Remove-Job -Force -ErrorAction SilentlyContinue

    # 4. Reclaim SQLite space (lightweight — only if pages freed)
    Invoke-SqliteQuery -DataSource $dbPath -Query "PRAGMA incremental_vacuum;"
}
```

### 8.3 SQLite Size Management

| Concern | Mitigation |
|---------|-----------|
| DB file growth | Results auto-delete on poll + timer cleanup every 15 min |
| WAL file growth | SQLite auto-checkpoints at 1000 WAL pages (~4 MB) |
| Fragmentation | `PRAGMA incremental_vacuum` in timer (lightweight) |
| Full VACUUM | Not needed — ephemeral DB is recreated on restart |

Expected steady-state DB size: **< 5 MB** (typically 0-2 active jobs × ~200 KB result each).

---

## 9. PipePal Frontend Integration

### 9.1 Proxy Changes: None Required

The `proxy-maester.ts` file already does everything correctly:

```typescript
// proxy-maester.ts — NO CHANGES NEEDED
// ✅ POST forwards body + Authorization header → works with Pode
// ✅ GET forwards jobId query param → works with Pode
// ✅ x-functions-key header → Pode reads same header for API key validation
// ✅ JSON response forwarding → identical format
```

**The only change needed:** Update `TARGET_URL` to point at the Docker container instead of Azure Functions:

```typescript
const TARGET_URL =
    process.env.AZURE_FUNCTION_MAESTER_URL ||
    'http://maester-api:80/api/MaesterRunner';   // Docker service name
```

Or keep the environment variable and set `AZURE_FUNCTION_MAESTER_URL=http://localhost:7071/api/MaesterRunner` in `.env.local`.

### 9.2 Response Format: Identical

The SQLite-backed Pode API returns the exact same JSON structure:

```
POST → 202 { jobId, status, createdAt }        ← identical
GET  → 200 { jobId, status, ..., result, error } ← identical
```

The `result` object within contains the same PipePal format:
```json
{
    "totalCount": 147,
    "passedCount": 120,
    "failedCount": 15,
    "skippedCount": 12,
    "durationMs": 312450,
    "timestamp": "...",
    "suitesRun": [...],
    "severityFilter": [...],
    "tests": [{ "id", "name", "result", "duration", "severity", "category", "block", "errorRecord" }]
}
```

### 9.3 Future Enhancement: Service Connection Status

Consider adding a `connections` field to the result (non-breaking addition):

```json
{
    "totalCount": 147,
    "connections": {
        "graph": true,
        "exchangeOnline": false,
        "microsoftTeams": false
    },
    "tests": [...]
}
```

PipePal can optionally display which services were connected, helping engineers understand why ORCA tests might show as "Skipped."

---

## 10. File Structure

### 10.1 Proposed Layout

```
maester-api/
├── Dockerfile                     # Alpine + pwsh + sqlite-libs + modules
├── docker-compose.yml             # Single service, no volumes by default
├── install-modules.ps1            # Build-time module install (+ PSSQLite)
├── .dockerignore                  # Exclude docs, tests, git
├── server.ps1                     # Pode HTTP server (main entrypoint)
├── lib/
│   ├── db.ps1                     # SQLite data access functions
│   ├── auth.ps1                   # Token extraction & validation helpers
│   ├── maester-runner.ps1         # Thread job scriptblock (test execution)
│   └── result-transformer.ps1     # Maester JSON → PipePal format
├── docs/
│   └── PODE_API_ARCHITECTURE.md   # This document
├── MaesterRunner/                 # KEEP — Azure Functions reference impl
│   ├── run.ps1
│   └── function.json
└── ...                            # Existing Azure Functions files (kept for reference)
```

### 10.2 Module Responsibilities

**`server.ps1`** (~150 lines, down from 395):
- Import modules + source `lib/*.ps1` scripts
- Initialize SQLite DB on startup
- Define Pode routes (health, GET, POST)
- Define Pode middleware (API key validation)
- Define Pode timer (cleanup)
- Delegate business logic to `lib/` modules

**`lib/db.ps1`** (~80 lines):
- `Initialize-MaesterDb` — CREATE TABLE IF NOT EXISTS
- `New-MaesterJob` — INSERT
- `Get-MaesterJob` — SELECT
- `Update-MaesterJob` — UPDATE
- `Remove-MaesterJob` — DELETE
- `Remove-ExpiredJobs` — batch cleanup
- `Get-StaleRunningJobs` — stale detection

**`lib/auth.ps1`** (~30 lines):
- `Get-BearerToken` — extract from Authorization header
- `Test-ApiKey` — validate X-Functions-Key against env var

**`lib/maester-runner.ps1`** (~200 lines):
- The complete `Start-ThreadJob` scriptblock
- Service connections (Graph + optional Exchange/Teams)
- Test path resolution
- Pester configuration building
- Maester invocation
- Result transformation → PipePal format
- SQLite update on completion/failure

**`lib/result-transformer.ps1`** (~50 lines):
- `ConvertTo-PipePalResult` — transforms Maester JSON output to flat test array + summary
- Extracted for testability and reuse

### 10.3 Why Modularize?

| Benefit | Details |
|---------|---------|
| **Readability** | `server.ps1` is a thin orchestrator, not a 400-line monolith |
| **Testability** | Each `lib/*.ps1` can be unit-tested independently |
| **Reusability** | `result-transformer.ps1` is identical logic to `run.ps1` — single source |
| **Maintainability** | Changing DB logic doesn't touch server routes |
| **Docker COPY** | `COPY lib/ /app/lib/` — clear build context |

---

## 11. Implementation Phases

### Phase 1: Core SQLite Migration (Priority: High)

**Goal:** Replace JSON file persistence with SQLite, all existing features preserved.

| Task | Files | Notes |
|------|-------|-------|
| Add `PSSQLite` to modules | `install-modules.ps1` | One line addition |
| Add `sqlite-libs` to image | `Dockerfile` | `apk add --no-cache sqlite-libs` |
| Create `lib/db.ps1` | New file | All SQLite operations |
| Create `lib/auth.ps1` | New file | Token + API key helpers |
| Create `lib/result-transformer.ps1` | New file | Extract from current scriptblock |
| Create `lib/maester-runner.ps1` | New file | Thread job scriptblock |
| Rewrite `server.ps1` | Existing file | Thin orchestrator using lib/ |
| Update `docker-compose.yml` | Existing file | Remove volume, add env vars |
| Test: full POST→poll→result cycle | Manual | Smoke test with real Graph token |

**Estimated effort:** 4-6 hours

### Phase 2: Enhanced Health & Observability (Priority: Medium)

| Task | Files | Notes |
|------|-------|-------|
| Enhanced `/health` with uptime + DB status | `server.ps1` | Non-breaking addition |
| Concurrency guard (max 5 running jobs) | `server.ps1` POST route | 409 Conflict response |
| Pode timer for periodic cleanup | `server.ps1` | 15-minute interval |
| Structured logging with timestamps | All `lib/` files | Write-Host with prefixes |

**Estimated effort:** 2-3 hours

### Phase 3: Exchange/Teams Integration (Priority: Low — Future)

> **Research finding:** Each service requires a token with its own OAuth audience.
> A single Graph token cannot authenticate Exchange or Teams.
> See Section 6.2 for full details.

| Task | Files | Notes |
|------|-------|-------|
| PipePal: acquire Exchange token | `TenantWorkspaceContext.tsx` | `acquireTokenSilent({ scopes: ['https://outlook.office365.com/.default'] })` |
| PipePal: acquire Teams token | `TenantWorkspaceContext.tsx` | `acquireTokenSilent({ scopes: ['48ac35b8-.../.default'] })` |
| PipePal proxy: forward extra headers | `proxy-maester.ts` | Forward `X-Exchange-Token`, `X-Teams-Token` |
| Backend: read Exchange token | `lib/auth.ps1` | `$Headers['X-Exchange-Token']` |
| Backend: read Teams token | `lib/auth.ps1` | `$Headers['X-Teams-Token']` |
| Connect-ExchangeOnline in thread job | `lib/maester-runner.ps1` | `-AccessToken $exoToken -Organization $domain` (try/catch) |
| Connect-MicrosoftTeams in thread job | `lib/maester-runner.ps1` | `-AccessTokens @($graphToken, $teamsToken)` (try/catch) |
| Add `connections` field to result | `lib/result-transformer.ps1` | Non-breaking JSON addition |

**Estimated effort:** 4-8 hours (including PipePal changes + scope testing)

### Phase 4: Production Hardening (Priority: Medium — Before Deployment)

| Task | Files | Notes |
|------|-------|-------|
| Rate limiting (max N requests/minute) | `server.ps1` middleware | Prevent abuse |
| Request body size limit | Pode config | Prevent large payloads |
| Structured JSON logging | All files | For log aggregation |
| Docker multi-stage build (optional) | `Dockerfile` | Reduce final image size |
| Kubernetes/ACI deployment manifests | New files | For cloud deployment |
| TLS termination strategy | Docs | Reverse proxy or Pode HTTPS |

**Estimated effort:** 4-6 hours

---

## 12. Security Considerations

### 12.1 Token Handling

| Requirement | Implementation |
|-------------|---------------|
| Tokens in headers only | `Authorization: Bearer <token>` — never in body or query string |
| Tokens never persisted | Token is an argument to `Start-ThreadJob`, not stored in SQLite |
| Token lifetime | Delegated tokens expire in 1 hour — thread job must complete within that time |
| Token single-use principle | Each POST creates one connection → one test run → disconnect |

### 12.2 API Key Security

| Requirement | Implementation |
|-------------|---------------|
| Container-level auth | `MAESTER_API_KEY` env var, checked on every request |
| Key rotation | Change env var → restart container (no code change) |
| Key comparison | Constant-time string comparison to prevent timing attacks |
| No anonymous access | All routes except `/health` require API key |

### 12.3 Container Security

| Measure | Status |
|---------|--------|
| Non-root user | **TODO** — add `USER` directive in Dockerfile |
| Read-only filesystem | `/app` is read-only, writes only to `/tmp/` |
| No secrets in image | API key via env var, token via request header |
| Minimal packages | Only `sqlite-libs` added beyond base image |
| Network isolation | Expose only port 80, Docker network for internal communication |

**Dockerfile addition for non-root:**
```dockerfile
RUN adduser -D -h /app maester
USER maester
```

### 12.4 Input Validation

| Input | Validation |
|-------|-----------|
| `suites` | Array of strings, validated against allowed list: `['maester','eidsca','cis','cisa','orca']` |
| `severity` | Array of strings, validated against: `['Critical','High','Medium','Low','Info']` |
| `tags` | Array of strings, max 20 items, no SQL injection (parameterized queries) |
| `includeLongRunning` | Boolean only |
| `includePreview` | Boolean only |
| `jobId` | Alphanumeric string, exactly 32 characters (GUID with no dashes) |

---

## 13. Open Questions — All Resolved ✅

> All questions were reviewed and resolved on 2025-07-15.

1. **Ephemeral vs. Persistent SQLite?** → ✅ **Ephemeral**
   - SQLite at `/tmp/maester.db`, no persistent volume
   - Data is transient by design — lost on container restart

2. **Concurrency limit?** → ✅ **5 concurrent jobs**
   - Max 5 running jobs simultaneously (return 409 Conflict if limit reached)
   - Configurable via `$MAX_CONCURRENT_JOBS` constant in `server.ps1`

3. **PSSQLite vs. raw SQLite CLI?** → ✅ **PSSQLite module**
   - Clean PowerShell integration, parameterized queries, type-safe
   - Adds ~2 MB to image (acceptable trade-off)

4. **API key header name?** → ✅ **Accept both headers**
   - `X-Functions-Key` (backward compat with PipePal proxy)
   - `X-Api-Key` (standard, future-proof)
   - Middleware checks both; first match wins

5. **Exchange/Teams auth strategy?** → ✅ **Graph-only Phase 1, multi-token Phase 3**
   - **Research finding:** A single Graph bearer token CANNOT authenticate to Exchange Online or Microsoft Teams — each service requires a token with its own audience:
     - Graph: `https://graph.microsoft.com`
     - Exchange: `https://outlook.office365.com`
     - Teams: `48ac35b8-9aa8-4d74-927d-1f4a14a0b239` (Skype & Teams Tenant Admin API)
   - **Teams** specifically requires TWO tokens: `Connect-MicrosoftTeams -AccessTokens @($GraphToken, $TeamsToken)`
   - **Phase 1:** Graph-only. PipePal sends single `Authorization: Bearer <graph-token>`
   - **Phase 3:** Multi-token. PipePal acquires per-audience tokens via `acquireTokenSilent()`, sends via separate headers (`X-Exchange-Token`, `X-Teams-Token`)
   - See Section 6.2 for full research findings and code examples

6. **lib/ modularization?** → ✅ **Split into lib/ modules**
   - `lib/db.ps1` — SQLite data access functions
   - `lib/auth.ps1` — Token extraction & API key validation
   - `lib/maester-runner.ps1` — Thread job scriptblock
   - `lib/result-transformer.ps1` — Maester JSON → PipePal format

---

## Appendix A: PSSQLite Quick Reference

```powershell
# Import
Import-Module PSSQLite

# Create table
Invoke-SqliteQuery -DataSource '/tmp/test.db' -Query @"
    CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, name TEXT)
"@

# Insert with parameters (SQL injection safe)
Invoke-SqliteQuery -DataSource '/tmp/test.db' -Query @"
    INSERT INTO items (id, name) VALUES (@id, @name)
"@ -SqlParameters @{ id = '123'; name = "Test Item" }

# Select
$rows = Invoke-SqliteQuery -DataSource '/tmp/test.db' -Query @"
    SELECT * FROM items WHERE id = @id
"@ -SqlParameters @{ id = '123' }

# Update
Invoke-SqliteQuery -DataSource '/tmp/test.db' -Query @"
    UPDATE items SET name = @name WHERE id = @id
"@ -SqlParameters @{ id = '123'; name = "Updated" }

# Delete
Invoke-SqliteQuery -DataSource '/tmp/test.db' -Query @"
    DELETE FROM items WHERE id = @id
"@ -SqlParameters @{ id = '123' }
```

---

## Appendix B: Full Request/Response Examples

### Start a Maester test run

```bash
# Start a test run with specific suites and severities
curl -X POST http://localhost:7071/api/MaesterRunner \
  -H "Authorization: Bearer eyJ0eXAi..." \
  -H "X-Functions-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "suites": ["maester", "eidsca"],
    "severity": ["Critical", "High"],
    "includeLongRunning": false
  }'

# Response: 202 Accepted
# {
#   "jobId": "a1b2c3d4e5f678901234567890abcdef",
#   "status": "running",
#   "createdAt": "2025-07-15T10:30:00.0000000Z"
# }
```

### Poll for results

```bash
# Poll job status
curl "http://localhost:7071/api/MaesterRunner?jobId=a1b2c3d4e5f678901234567890abcdef" \
  -H "X-Functions-Key: your-api-key"

# Response while running: 200 OK
# { "jobId": "...", "status": "running", ... }

# Response when complete: 200 OK
# { "jobId": "...", "status": "completed", "result": { ... } }
```

### Health check

```bash
curl http://localhost:7071/health
# { "status": "ok", "uptime": 3600, "dbConnected": true, "activeJobs": 0 }
```

---

_End of architecture proposal. Ready for review._
