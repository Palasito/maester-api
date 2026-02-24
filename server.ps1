# server.ps1 — Pode HTTP server for maester-api (Docker / Alpine)
#
# Thin orchestrator that delegates to lib/ modules for all business logic.
# Replaces the Azure Functions host when running in Docker.
#
# API contract:
#
#   POST /api/maester
#     Authorization: Bearer <graphToken>    (device code delegated token)
#     X-Exchange-Token: <token>             (optional, for Exchange Online tests)
#     X-Teams-Token: <token>                (optional, for Microsoft Teams tests)
#     X-IPPS-Token: <token>                 (optional, for Security & Compliance tests)
#     X-Functions-Key: <apiKey>   (or X-Api-Key)
#     Body: { suites, severity?, tags?, includeLongRunning?, includePreview?,
#             tenantId?, includeExchange?, includeTeams? }
#     Response 202: { jobId, status: "running", createdAt }
#
#   GET  /api/maester?jobId=<id>
#     X-Functions-Key: <apiKey>
#     Response 200: { jobId, status, createdAt, updatedAt, result?, error? }
#
#   GET  /health
#     Response 200: { status: "ok", uptime, dbConnected, activeJobs }

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

# ─── Import PowerShell modules ────────────────────────────────────────────────
# Only load modules required by the Pode HTTP server itself.
# Heavy modules (Pester, Graph.Auth, ExchangeOnlineManagement, MicrosoftTeams,
# Maester) are loaded ONLY in the child-process job (Start-Job) which runs in
# its own isolated pwsh process.  When the job exits, the OS reclaims all of
# its memory — keeping the long-running Pode process lean.
Write-Host '[server] Importing server modules...'
Import-Module -Name Pode     -ErrorAction Stop
Import-Module -Name PSSQLite -ErrorAction Stop
# NOTE: ThreadJob is intentionally NOT imported here. We use Start-Job (child
# process) instead of Start-ThreadJob (thread in same process) so that the
# ~300 MB of Maester/Pester/Graph module assemblies are fully reclaimed by the
# OS when the child process exits after a test run. With Start-ThreadJob those
# assemblies are loaded into the Pode process AppDomain and can never be freed.
Write-Host '[server] Server modules loaded (Pode, PSSQLite).'

# ─── Source lib/ helpers ──────────────────────────────────────────────────────
Write-Host '[server] Loading lib/ modules...'
. /app/lib/db.ps1
. /app/lib/auth.ps1
. /app/lib/result-transformer.ps1
. /app/lib/maester-runner.ps1
. /app/lib/inventory-builder.ps1
Write-Host '[server] lib/ modules loaded.'

# ─── Constants ────────────────────────────────────────────────────────────────
$DB_PATH             = if ($env:MAESTER_DB_PATH) { $env:MAESTER_DB_PATH } else { '/tmp/maester.db' }
# Only 1 concurrent job allowed — running two Maester runs against the same
# tenant simultaneously causes Graph API throttling (429s) and Exchange Online
# session conflicts that produce inconsistent / non-reproducible results.
$MAX_CONCURRENT_JOBS = 1
$JOB_STALE_MINUTES   = 30
$SERVER_START_TIME   = [datetime]::UtcNow
$MAESTER_TESTS_PATH  = '/app/maester-tests'

# ─── Refresh Maester test definitions (best-effort, subprocess) ──────────────
# The image ships with tests baked in at build time. At startup we attempt to
# pull the latest versions from GitHub so the container always runs the newest
# tests. The refresh runs in a CHILD pwsh process so that the Maester module's
# ~200 MB of .NET assemblies are never loaded into the long-running server
# process — the subprocess exits after completion and its memory is reclaimed.
Write-Host "[server] Refreshing Maester test definitions at $MAESTER_TESTS_PATH ..."
try {
    $refreshCmd = "Import-Module Maester -ErrorAction Stop; " +
                  "if (Test-Path '$MAESTER_TESTS_PATH') { Remove-Item '$MAESTER_TESTS_PATH' -Recurse -Force }; " +
                  "Install-MaesterTests -Path '$MAESTER_TESTS_PATH' -ErrorAction Stop"
    & pwsh -NoProfile -NonInteractive -Command $refreshCmd
    if ($LASTEXITCODE -eq 0) {
        $suiteCount = (Get-ChildItem $MAESTER_TESTS_PATH -Directory -ErrorAction SilentlyContinue).Count
        Write-Host "[server] Maester tests refreshed ($suiteCount suite directories)."
    } else {
        Write-Host "[server] WARNING: Test refresh subprocess failed (exit $LASTEXITCODE). Using build-time tests."
    }
} catch {
    Write-Host "[server] WARNING: Test refresh failed ($($_.Exception.Message)). Using build-time tests."
}

# ─── Build test inventory (cached for container lifetime) ─────────────────────
# Inventory is built once at startup from maester-config.json + directory
# structure. It only changes when the container restarts (Install-MaesterTests).
Write-Host '[server] Building test inventory ...'
try {
    $INVENTORY_CACHE = Build-MaesterInventory -TestsPath $MAESTER_TESTS_PATH
    $INVENTORY_JSON  = $INVENTORY_CACHE | ConvertTo-Json -Depth 12
    Write-Host '[server] Test inventory cached.'
} catch {
    Write-Host "[server] WARNING: Inventory build failed ($($_.Exception.Message)). /api/inventory will return 503."
    $INVENTORY_JSON = $null
}

# ─── Initialise SQLite ────────────────────────────────────────────────────────
Write-Host "[server] Initialising SQLite at $DB_PATH ..."
Initialize-MaesterDb -DbPath $DB_PATH
Write-Host '[server] SQLite ready.'

# ─── Start Pode HTTP server ──────────────────────────────────────────────────
Write-Host '[server] Starting Pode server on port 80...'

Start-PodeServer -Threads 1 {

    Add-PodeEndpoint -Address * -Port 80 -Protocol Http

    # ══════════════════════════════════════════════════════════════════════════
    # Middleware: API key validation on /api/* routes
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeMiddleware -Name 'ApiKeyAuth' -Route '/api/*' -ScriptBlock {
        # Re-source auth helpers (Pode runspaces don't share parent scope)
        . /app/lib/auth.ps1

        if (-not (Test-ApiKey -Headers $WebEvent.Request.Headers)) {
            $WebEvent.Response.StatusCode = 401
            Write-PodeJsonResponse -Value @{ error = 'Unauthorized — missing or invalid API key.' }
            return $false
        }
        return $true
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET /health — Container health check (no auth)
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        $dbPath    = $using:DB_PATH
        $startTime = $using:SERVER_START_TIME

        $dbOk       = $false
        $activeJobs = 0
        try {
            Import-Module PSSQLite -ErrorAction SilentlyContinue
            $row = Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'"
            $activeJobs = [int]$row.cnt
            $dbOk = $true
        } catch { }

        $uptimeSec = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)

        Write-PodeJsonResponse -Value ([ordered]@{
            status      = 'ok'
            uptime      = $uptimeSec
            dbConnected = $dbOk
            activeJobs  = $activeJobs
        })
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET /api/inventory — Return cached test inventory JSON
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/api/inventory' -ScriptBlock {
        $json = $using:INVENTORY_JSON

        if (-not $json) {
            $WebEvent.Response.StatusCode = 503
            Write-PodeJsonResponse -Value @{ error = 'Inventory not available — build failed at startup.' }
            return
        }

        Write-PodeTextResponse -Value $json -ContentType 'application/json'
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET /api/maester — Poll job status
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/api/maester' -ScriptBlock {
        $dbPath       = $using:DB_PATH
        $staleMinutes = $using:JOB_STALE_MINUTES

        Import-Module PSSQLite -ErrorAction SilentlyContinue

        # ── Validate jobId ────────────────────────────────────────────────────
        $jobId = $WebEvent.Query['jobId']
        if (-not $jobId) {
            $WebEvent.Response.StatusCode = 400
            Write-PodeJsonResponse -Value @{ error = 'Missing required query parameter: jobId' }
            return
        }

        # ── Fetch from SQLite ─────────────────────────────────────────────────
        $job = Invoke-SqliteQuery -DataSource $dbPath -Query @"
            SELECT * FROM jobs WHERE job_id = @jobId
"@ -SqlParameters @{ jobId = $jobId }

        if (-not $job) {
            $WebEvent.Response.StatusCode = 404
            Write-PodeJsonResponse -Value ([ordered]@{ error = "Job not found: $jobId" })
            return
        }

        # ── Stale job detection ───────────────────────────────────────────────
        if ($job.status -eq 'running' -and $job.created_at) {
            try {
                $created = [datetime]::Parse($job.created_at).ToUniversalTime()
                $elapsed = ([datetime]::UtcNow - $created).TotalMinutes
                if ($elapsed -gt $staleMinutes) {
                    $now = [datetime]::UtcNow.ToString('o')
                    Invoke-SqliteQuery -DataSource $dbPath -Query @"
                        UPDATE jobs
                        SET    status = 'failed',
                               error  = @error,
                               updated_at = @now
                        WHERE  job_id = @jobId AND status = 'running'
"@ -SqlParameters @{
                        jobId = $jobId
                        error = "Job timed out after $([math]::Round($elapsed)) minutes."
                        now   = $now
                    }
                    # Re-read the updated row
                    $job = Invoke-SqliteQuery -DataSource $dbPath -Query @"
                        SELECT * FROM jobs WHERE job_id = @jobId
"@ -SqlParameters @{ jobId = $jobId }
                }
            } catch { }
        }

        # ── Build response ────────────────────────────────────────────────────
        $response = [ordered]@{
            jobId     = $job.job_id
            status    = $job.status
            createdAt = $job.created_at
            updatedAt = $job.updated_at
            result    = $null
            error     = $job.error
        }

        # Parse result JSON back into an object (not a string)
        if ($job.result) {
            try   { $response.result = $job.result | ConvertFrom-Json }
            catch { $response.result = $job.result }
        }

        # ── Terminal-state cleanup: delete row after returning ─────────────────
        # Also call Remove-Job here so the child pwsh process is reaped
        # immediately when the frontend picks up the final result, rather than
        # waiting up to 15 minutes for the scheduled cleanup timer.
        if ($job.status -in @('completed', 'failed')) {
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
                DELETE FROM jobs WHERE job_id = @jobId
"@ -SqlParameters @{ jobId = $jobId } -ErrorAction SilentlyContinue

            try {
                Get-Job -Name "maester-$($job.job_id)" -ErrorAction SilentlyContinue |
                    Remove-Job -Force -ErrorAction SilentlyContinue
            } catch { }
        }

        Write-PodeJsonResponse -Value ($response | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }

    # ══════════════════════════════════════════════════════════════════════════
    # POST /api/maester — Start a new Maester test run
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Post -Path '/api/maester' -ScriptBlock {
        $dbPath           = $using:DB_PATH
        $maxConcurrent    = $using:MAX_CONCURRENT_JOBS
        $runnerScriptBlock = $using:MaesterRunnerScriptBlock
        $testsPath         = $using:MAESTER_TESTS_PATH

        Import-Module PSSQLite -ErrorAction SilentlyContinue
        . /app/lib/auth.ps1

        # ── 1. Extract bearer token (device code delegated flow) ─────────────
        $rawToken = Get-BearerToken -Headers $WebEvent.Request.Headers
        if (-not $rawToken) {
            $WebEvent.Response.StatusCode = 401
            Write-PodeJsonResponse -Value @{
                error = 'Missing authentication. Provide Authorization: Bearer <token>.'
            }
            return
        }

        # ── 1a. Extract optional app-registration credentials ──────────────────
        # The runner uses these to acquire all service tokens (Exchange, IPPS,
        # Teams, Azure) itself via client_credentials grant.
        $maesterClientId     = $WebEvent.Request.Headers['X-Maester-Client-Id']
        $maesterClientSecret = $WebEvent.Request.Headers['X-Maester-Client-Secret']

        # ── 2. Parse request body ────────────────────────────────────────────
        try {
            $body           = $WebEvent.Data
            $suites         = if ($body.suites)                       { @($body.suites) }             else { @('maester','cisa','eidsca','orca','cis') }
            $severities     = if ($body.severity)                     { @($body.severity) }           else { @('Critical','High','Medium','Low','Info') }
            $extraTags      = if ($body.tags)                         { @($body.tags) }               else { @() }
            $incLongRunning = if ($null -ne $body.includeLongRunning) { [bool]$body.includeLongRunning } else { $true  }
            # Default Preview to $true — many EIDSCA tests are tagged Preview and excluding
            # them by default was causing the majority of skipped results.
            $incPreview     = if ($null -ne $body.includePreview)     { [bool]$body.includePreview }     else { $true  }

            # Phase 3: tenantId needed for Exchange Online connection (-Organization)
            $tenantId       = if ($body.tenantId) { [string]$body.tenantId } else { '' }

        } catch {
            $WebEvent.Response.StatusCode = 400
            Write-PodeJsonResponse -Value ([ordered]@{ error = "Failed to parse request body: $($_.Exception.Message)" })
            return
        }

        # ── 3. Concurrency guard (per-tenant) ────────────────────────────────
        # One run at a time per tenant. Different tenants may run in parallel.
        $runningCount = (Invoke-SqliteQuery -DataSource $dbPath -Query @"
            SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running' AND tenant_id = @tenantId
"@ -SqlParameters @{ tenantId = $tenantId }).cnt

        if ([int]$runningCount -ge $maxConcurrent) {
            $WebEvent.Response.StatusCode = 409
            Write-PodeJsonResponse -Value @{
                error = "A Maester test run is already in progress for this tenant. Running two concurrent scans against the same tenant causes Graph API throttling and inconsistent results. Please wait for the current run to complete."
            }
            return
        }

        # ── 4. Create job in SQLite ──────────────────────────────────────────
        $jobId = [guid]::NewGuid().ToString('N')
        $now   = [datetime]::UtcNow.ToString('o')

        Invoke-SqliteQuery -DataSource $dbPath -Query @"
            INSERT INTO jobs (job_id, status, created_at, updated_at, suites, severity, tenant_id)
            VALUES (@jobId, 'running', @now, @now, @suites, @severity, @tenantId)
"@ -SqlParameters @{
            jobId    = $jobId
            now      = $now
            suites   = ($suites   | ConvertTo-Json -Compress)
            severity = ($severities | ConvertTo-Json -Compress)
            tenantId = $tenantId
        }

        # ── 5. Cleanup expired jobs ──────────────────────────────────────────
        try {
            $hardCutoff      = [datetime]::UtcNow.AddHours(-2).ToString('o')
            $completedCutoff = [datetime]::UtcNow.AddMinutes(-10).ToString('o')

            Invoke-SqliteQuery -DataSource $dbPath -Query @"
                DELETE FROM jobs WHERE created_at < @cutoff
"@ -SqlParameters @{ cutoff = $hardCutoff } -ErrorAction SilentlyContinue

            Invoke-SqliteQuery -DataSource $dbPath -Query @"
                DELETE FROM jobs
                WHERE  status IN ('completed', 'failed')
                  AND  updated_at < @cutoff
"@ -SqlParameters @{ cutoff = $completedCutoff } -ErrorAction SilentlyContinue
        } catch { }

        # Cleanup completed PowerShell jobs
        try {
            Get-Job | Where-Object { $_.State -in @('Completed', 'Failed') } |
                Remove-Job -Force -ErrorAction SilentlyContinue
        } catch { }

        # ── 6. Launch background thread job ──────────────────────────────────
        # Start-Job (child process) rather than Start-ThreadJob (thread).
        # Child processes have an isolated memory space; once the run finishes
        # and Remove-Job is called (either here on the next launch or in the
        # GET handler above), the OS reclaims all Maester/Pester/Graph memory.
        $null = Start-Job -Name "maester-$jobId" -ScriptBlock $runnerScriptBlock -ArgumentList @(
            $rawToken, $suites, $severities, $extraTags,
            $incLongRunning, $incPreview, $jobId, $dbPath,
            $tenantId, $testsPath,
            $maesterClientId, $maesterClientSecret
        )

        # ── 7. Return 202 Accepted ───────────────────────────────────────────
        $WebEvent.Response.StatusCode = 202
        Write-PodeJsonResponse -Value ([ordered]@{
            jobId     = $jobId
            status    = 'running'
            createdAt = $now
        })
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Scheduled Timer: cleanup stale & expired jobs every 15 minutes
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeTimer -Name 'JobCleanup' -Interval 900 -ScriptBlock {
        $dbPath       = $using:DB_PATH
        $staleMinutes = $using:JOB_STALE_MINUTES

        Import-Module PSSQLite -ErrorAction SilentlyContinue

        try {
            # 1. Mark stale running jobs as failed
            $cutoff = [datetime]::UtcNow.AddMinutes(-$staleMinutes).ToString('o')
            $now    = [datetime]::UtcNow.ToString('o')
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
                UPDATE jobs
                SET    status = 'failed',
                       error  = 'Job timed out (cleanup timer). Container may have restarted.',
                       updated_at = @now
                WHERE  status = 'running' AND created_at < @cutoff
"@ -SqlParameters @{ cutoff = $cutoff; now = $now }

            # 2. Delete expired jobs (>2h old)
            $hardCutoff = [datetime]::UtcNow.AddHours(-2).ToString('o')
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
                DELETE FROM jobs WHERE created_at < @cutoff
"@ -SqlParameters @{ cutoff = $hardCutoff }

            # 3. Cleanup completed PowerShell thread jobs
            Get-Job | Where-Object { $_.State -in @('Completed', 'Failed') } |
                Remove-Job -Force -ErrorAction SilentlyContinue

            # 4. Reclaim SQLite space
            Invoke-SqliteQuery -DataSource $dbPath -Query 'PRAGMA incremental_vacuum;'
        }
        catch { }
    }
}
