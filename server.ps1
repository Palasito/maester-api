# server.ps1 — Pode HTTP server for maester-api (Docker / Alpine)
#
# Thin orchestrator that delegates to lib/ modules for all business logic.
# Replaces the Azure Functions host when running in Docker.
#
# API contract:
#
#   POST /api/maester
#     Authorization: Bearer <token>         (MSAL workspace token — BASE scopes for proxy auth)
#     X-Maester-Client-Id: <clientId>       (app-registration credentials for client_credentials grant)
#     X-Maester-Client-Secret: <secret>     (app-registration secret)
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
# NOTE: Microsoft.Data.Sqlite + SQLitePCLRaw assemblies are loaded by lib/db.ps1.
# No PSSQLite Import-Module needed — all SQL goes through raw ADO.NET.
# NOTE: ThreadJob is intentionally NOT imported here. We use Start-Job (child
# process) instead of Start-ThreadJob (thread in same process) so that the
# ~300 MB of Maester/Pester/Graph module assemblies are fully reclaimed by the
# OS when the child process exits after a test run. With Start-ThreadJob those
# assemblies are loaded into the Pode process AppDomain and can never be freed.
Write-Host '[server] Server modules loaded (Pode).'

# ─── Source lib/ helpers ──────────────────────────────────────────────────────
Write-Host '[server] Loading lib/ modules...'
. /app/lib/db.ps1
. /app/lib/auth.ps1
. /app/lib/result-transformer.ps1
. /app/lib/maester-runner.ps1
. /app/lib/inventory-builder.ps1
Write-Host '[server] lib/ modules loaded.'

# ─── Pre-build route-handler function blocks ──────────────────────────────────
# Pode runspaces don't inherit the parent scope's functions. Previously, route
# handlers re-sourced lib/*.ps1 on EVERY request — reading files, parsing AST,
# creating new FunctionInfo objects each time. These PowerShell metadata objects
# accumulate in the .NET type system and contribute to monotonic memory growth.
#
# Fix: Define the route-needed logic as ScriptBlocks here, captured via $using:
# in route handlers. The ScriptBlock is serialized ONCE into the runspace and
# reused on every request — zero file I/O, zero AST parsing, zero growth.

$TestApiKeyBlock = {
    param($Headers)
    $expected = $env:MAESTER_API_KEY
    if (-not $expected) { return $false }
    $key = $Headers['X-Functions-Key']
    if (-not $key) { $key = $Headers['X-Api-Key'] }
    if (-not $key) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [System.Text.Encoding]::UTF8.GetBytes($key),
        [System.Text.Encoding]::UTF8.GetBytes($expected)
    )
}

$GetBearerTokenBlock = {
    param($Headers)
    $authHeader = $Headers['Authorization']
    if (-not $authHeader) { return $null }
    if (-not $authHeader.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $token = $authHeader.Substring(7).Trim()
    if ($token.Length -lt 10) { return $null }
    return $token
}

$TestValidTenantIdBlock = {
    param([string]$TenantId)
    $guidResult = [guid]::Empty
    return [guid]::TryParse($TenantId, [ref]$guidResult)
}

$RecordJobCompletionBlock = {
    param([string]$DbPath, [string]$JobId, [string]$Status, [int]$DurationMs, [string]$Suites)
    $now  = [datetime]::UtcNow.ToString('o')
    $conn = $null; $cmd = $null
    try {
        $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$DbPath")
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'INSERT INTO job_stats (job_id, status, duration_ms, suites, completed_at) VALUES (@jobId, @status, @durationMs, @suites, @now)'
        $null = $cmd.Parameters.AddWithValue('@jobId',      $JobId)
        $null = $cmd.Parameters.AddWithValue('@status',     $Status)
        $null = $cmd.Parameters.AddWithValue('@durationMs', $DurationMs)
        $null = $cmd.Parameters.AddWithValue('@suites',     $Suites)
        $null = $cmd.Parameters.AddWithValue('@now',        $now)
        $null = $cmd.ExecuteNonQuery()
    } finally {
        if ($cmd)  { $cmd.Dispose() }
        if ($conn) { $conn.Dispose() }
    }
}

$FormatDurationBlock = {
    param([int]$ms)
    if ($ms -le 0) { return 'N/A' }
    $totalSec = [math]::Round($ms / 1000)
    if ($totalSec -lt 60) { return "${totalSec}s" }
    $m = [math]::Floor($totalSec / 60)
    $s = $totalSec % 60
    return "${m}m ${s}s"
}

Write-Host '[server] Route handler ScriptBlocks pre-built.'

# ─── Security: Validate required environment variables at startup ─────────────
if (-not $env:MAESTER_API_KEY) {
    Write-Error '[server] FATAL: MAESTER_API_KEY environment variable is not set. The API will deny ALL requests (fail-closed). Set this variable before starting the server.'
    # Don't exit — the server can still start (fail-closed is safe), but warn loudly.
    Write-Host '[server] WARNING: Server starting in LOCKDOWN mode — all /api/* requests will be rejected.'
}

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

# ─── Pre-compute initial health data ─────────────────────────────────────────
# Seed health cache once at startup so the first 30 seconds of dashboard/health
# requests return real data instead of zeros.
$INITIAL_HEALTH = @{
    dbConnected     = $false
    activeJobs      = [int]0
    totalCompleted  = [int]0
    totalFailed     = [int]0
    avgDurationMs   = [int]0
    minDurationMs   = [int]0
    maxDurationMs   = [int]0
    lastCompletedAt = $null
    # Pre-formatted duration strings for dashboard (avoids Format-Duration per request)
    avgDurationStr  = 'N/A'
    minDurationStr  = 'N/A'
    maxDurationStr  = 'N/A'
}
try {
    $initConn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$DB_PATH")
    try {
        $initConn.Open()
        $initCmd = $initConn.CreateCommand()
        $initCmd.CommandText = "SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'"
        $INITIAL_HEALTH.activeJobs = [int]$initCmd.ExecuteScalar()
        $initCmd.Dispose()
    } finally { $initConn.Dispose() }
    $initStats = Get-JobStats -DbPath $DB_PATH
    if ($initStats) {
        $INITIAL_HEALTH.totalCompleted  = [int]$initStats.totalCompleted
        $INITIAL_HEALTH.totalFailed     = [int]$initStats.totalFailed
        $INITIAL_HEALTH.avgDurationMs   = [int]$initStats.avgDurationMs
        $INITIAL_HEALTH.minDurationMs   = [int]$initStats.minDurationMs
        $INITIAL_HEALTH.maxDurationMs   = [int]$initStats.maxDurationMs
        $INITIAL_HEALTH.lastCompletedAt = $initStats.lastCompletedAt
    }
    $INITIAL_HEALTH.dbConnected = $true
    Write-Host '[server] Initial health data seeded from SQLite.'
} catch {
    Write-Host "[server] WARNING: Could not seed health data ($($_.Exception.Message)). Will populate on first timer tick."
}

# ─── Pre-build initial /health JSON ──────────────────────────────────────────
# Seed so the first 30 seconds of /health requests return data immediately.
# ResourceSampler timer rebuilds this every 30 seconds thereafter.
$INITIAL_HEALTH_JSON = ConvertTo-Json -Depth 4 -Compress -InputObject ([ordered]@{
    status          = 'ok'
    uptime          = 0
    dbConnected     = $INITIAL_HEALTH.dbConnected
    activeJobs      = $INITIAL_HEALTH.activeJobs
    cpuPercent      = [double]0
    cpuAvgPercent   = [double]0
    ramUsedMB       = [double]0
    ramTotalMB      = [double]0
    ramPercent      = [double]0
    ramAvgMB        = [double]0
    ramAvgPercent   = [double]0
    totalCompleted  = $INITIAL_HEALTH.totalCompleted
    totalFailed     = $INITIAL_HEALTH.totalFailed
    avgDurationMs   = $INITIAL_HEALTH.avgDurationMs
    minDurationMs   = $INITIAL_HEALTH.minDurationMs
    maxDurationMs   = $INITIAL_HEALTH.maxDurationMs
    lastCompletedAt = $INITIAL_HEALTH.lastCompletedAt
})

# ─── Start Pode HTTP server ──────────────────────────────────────────────────
Write-Host '[server] Starting Pode server on port 80...'

Start-PodeServer -Threads 1 {

    Add-PodeEndpoint -Address * -Port 80 -Protocol Http

    # ══════════════════════════════════════════════════════════════════════════
    # Security: Response headers middleware (all routes)
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeMiddleware -Name 'SecurityHeaders' -ScriptBlock {
        # Prevent MIME-type sniffing
        $WebEvent.Response.Headers['X-Content-Type-Options'] = 'nosniff'
        # Prevent clickjacking
        $WebEvent.Response.Headers['X-Frame-Options'] = 'DENY'
        # Referrer policy
        $WebEvent.Response.Headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
        # Disable unnecessary browser features
        $WebEvent.Response.Headers['Permissions-Policy'] = 'geolocation=(), microphone=(), camera=()'
        # XSS protection for legacy browsers
        $WebEvent.Response.Headers['X-XSS-Protection'] = '1; mode=block'
        # Force HTTPS (respected when behind TLS-terminating proxy)
        $WebEvent.Response.Headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
        # Cache-Control: prevent caching of API responses
        $WebEvent.Response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
        $WebEvent.Response.Headers['Pragma'] = 'no-cache'
        return $true
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Security: CORS — restrict to known origins only
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeMiddleware -Name 'CorsPolicy' -ScriptBlock {
        $origin = $WebEvent.Request.Headers['Origin']
        # Allow requests with no Origin header (same-origin, curl, health checks)
        if ($origin) {
            $allowedOrigins = @(
                'https://pipepal.azurewebsites.net',
                'http://localhost:3000'
            )
            if ($origin -in $allowedOrigins) {
                $WebEvent.Response.Headers['Access-Control-Allow-Origin']  = $origin
                $WebEvent.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
                $WebEvent.Response.Headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, X-Functions-Key, X-Api-Key, X-Maester-Client-Id, X-Maester-Client-Secret'
                $WebEvent.Response.Headers['Access-Control-Max-Age']       = '86400'
                $WebEvent.Response.Headers['Vary']                         = 'Origin'
            }
            # Reject preflight from unknown origins
            if ($WebEvent.Request.Method -eq 'OPTIONS') {
                if ($origin -notin $allowedOrigins) {
                    $WebEvent.Response.StatusCode = 403
                    Write-PodeJsonResponse -Value @{ error = 'Origin not allowed.' }
                    return $false
                }
                $WebEvent.Response.StatusCode = 204
                return $false
            }
        }
        return $true
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Security: Rate limiting state (in-memory sliding window)
    # ══════════════════════════════════════════════════════════════════════════
    Set-PodeState -Name 'RateLimiter' -Value @{
        # IP → list of request timestamps (sliding window)
        Requests = [hashtable]::Synchronized(@{})
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Health data cache (updated every 30s by ResourceSampler timer).
    # /health and GET / read from this cache instead of querying SQLite
    # on every request — eliminates dot-sourcing and Import-Module per call.
    # ══════════════════════════════════════════════════════════════════════════
    Set-PodeState -Name 'HealthCache' -Value $INITIAL_HEALTH
    Set-PodeState -Name 'HealthJson' -Value $INITIAL_HEALTH_JSON

    Add-PodeMiddleware -Name 'RateLimiter' -Route '/api/*' -ScriptBlock {
        $maxRequests   = 30    # Max requests per window
        $windowSeconds = 60    # Sliding window size

        $clientIp = $WebEvent.Request.RemoteEndPoint.Address.ToString()
        if (-not $clientIp) { $clientIp = 'unknown' }

        $now    = [datetime]::UtcNow
        $cutoff = $now.AddSeconds(-$windowSeconds)

        # LOCK-FREE: With -Threads 1, only one request thread exists.
        # The Synchronized hashtable handles atomic per-key access.
        # Previous Lock-PodeObject created closure allocations per request.
        $rl = Get-PodeState -Name 'RateLimiter'
        if (-not $rl.Requests.ContainsKey($clientIp)) {
            $rl.Requests[$clientIp] = [System.Collections.ArrayList]::new()
        }
        $timestamps = $rl.Requests[$clientIp]

        # Purge expired timestamps (reverse foreach avoids Where-Object pipeline allocations)
        for ($i = $timestamps.Count - 1; $i -ge 0; $i--) {
            if ($timestamps[$i] -lt $cutoff) {
                $timestamps.RemoveAt($i)
            }
        }

        # Clean stale IPs — empty ArrayLists from old clients (health probes, etc.)
        # Uses snapshot + foreach instead of Where-Object to avoid enumerator allocations.
        $keysSnapshot = @($rl.Requests.Keys)
        foreach ($ip in $keysSnapshot) {
            if ($ip -ne $clientIp -and $rl.Requests[$ip].Count -eq 0) {
                $rl.Requests.Remove($ip)
            }
        }

        if ($timestamps.Count -ge $maxRequests) {
            $WebEvent.Response.StatusCode = 429
            $WebEvent.Response.Headers['Retry-After'] = $windowSeconds.ToString()
            Write-PodeJsonResponse -Value @{ error = 'Too many requests. Please slow down.' }
            return $false
        }

        $null = $timestamps.Add($now)
        return $true
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Resource monitoring: CPU + RAM sampling every 120 seconds
    # ══════════════════════════════════════════════════════════════════════════
    # Seed initial /proc/stat reading so the first timer tick can compute a delta.
    $initCpuIdle  = [long]0
    $initCpuTotal = [long]1   # avoid div-by-zero
    try {
        $cpuLine   = (Get-Content /proc/stat -TotalCount 1) -replace '^cpu\s+', ''
        $cpuFields = $cpuLine -split '\s+' | ForEach-Object { [long]$_ }
        $initCpuIdle  = [long]$cpuFields[3] + [long]$cpuFields[4]   # idle + iowait
        $initCpuTotal = ($cpuFields | Measure-Object -Sum).Sum
    } catch { }

    Set-PodeState -Name 'ResourceMonitor' -Value @{
        # Fixed-size circular buffer — avoids ArrayList.RemoveAt(0) O(n) copy + heap fragmentation
        Samples      = [object[]]::new(30)    # 30 slots × 300s ≈ 2.5 hours
        WriteIndex   = [int]0                  # Next write position
        Count        = [int]0                  # Valid samples (grows to 30 then stays)
        LastCpuIdle  = $initCpuIdle
        LastCpuTotal = $initCpuTotal
        # Pre-computed values so /health doesn't need to iterate the buffer
        LatestCpuPercent = [double]0
        LatestRamUsedMB  = [double]0
        LatestRamTotalMB = [double]0
        AvgCpuPercent    = [double]0
        AvgRamUsedMB     = [double]0
        # Reused across ticks to avoid per-tick allocations
        CapturedValues   = @{ cpu = [double]0; cpuAvg = [double]0; ram = [double]0; ramMax = [double]0; ramAvg = [double]0 }
        JsonBuilder      = [System.Text.StringBuilder]::new(512)
        # Tick counter for merged sub-tasks: HealthRefresher (every 2nd = ~600s) + MemoryLogger (every 6th = ~1800s)
        TickCount        = [int]0
        # Pre-built /health JSON string — updated each tick, read by /health route
        HealthJson       = $INITIAL_HEALTH_JSON
    }

    # ── Pre-capture PodeState references for $using: access ───────────────
    # Eliminates 7+ Get-PodeState/Set-PodeState cmdlet calls per timer tick.
    # Each cmdlet invocation creates ~10 .NET objects (CommandProcessor,
    # ParameterBinding, PipelineProcessor) that accumulate in Gen2 over time.
    $_resmon   = Get-PodeState -Name 'ResourceMonitor'
    $_hcache   = Get-PodeState -Name 'HealthCache'
    $_CgroupV2 = [System.IO.File]::Exists('/sys/fs/cgroup/memory.current')

    Add-PodeTimer -Name 'ResourceSampler' -Interval 300 -ScriptBlock {
        $startTime = $using:SERVER_START_TIME
        $dbPath    = $using:DB_PATH
        $fmtDur    = $using:FormatDurationBlock
        $cgV2      = $using:_CgroupV2
        $mon       = $using:_resmon
        $hc        = $using:_hcache
        try {
            # ── CPU from /proc/stat (StreamReader avoids Get-Content overhead) ─
            $sr = [System.IO.StreamReader]::new('/proc/stat')
            $cpuLine = $sr.ReadLine() -replace '^cpu\s+', ''
            $sr.Dispose(); $sr = $null
            $fields = $cpuLine -split '\s+'
            $idle   = [long]$fields[3] + [long]$fields[4]
            $total  = [long]0
            foreach ($f in $fields) { $total += [long]$f }

            # ── RAM from cgroup (File I/O avoids Get-Content cmdlet overhead) ─
            $ramUsedMB = [double]0; $ramTotalMB = [double]0
            if ($cgV2) {
                # cgroup v2
                $ramUsedMB  = [math]::Round([long]([System.IO.File]::ReadAllText('/sys/fs/cgroup/memory.current').Trim()) / 1MB, 1)
                $maxRaw     = [System.IO.File]::ReadAllText('/sys/fs/cgroup/memory.max').Trim()
                $ramTotalMB = if ($maxRaw -eq 'max') { 0 } else { [math]::Round([long]$maxRaw / 1MB, 1) }
            }
            elseif ([System.IO.File]::Exists('/sys/fs/cgroup/memory/memory.usage_in_bytes')) {
                # cgroup v1
                $ramUsedMB  = [math]::Round([long]([System.IO.File]::ReadAllText('/sys/fs/cgroup/memory/memory.usage_in_bytes').Trim()) / 1MB, 1)
                $limitRaw   = [System.IO.File]::ReadAllText('/sys/fs/cgroup/memory/memory.limit_in_bytes').Trim()
                $ramTotalMB = if ([long]$limitRaw -gt 1TB) { 0 } else { [math]::Round([long]$limitRaw / 1MB, 1) }
            }
            else {
                # Bare-metal / VM fallback via /proc/meminfo
                $memInfo = Get-Content /proc/meminfo -ErrorAction SilentlyContinue
                $totalKB = [long](($memInfo | Where-Object { $_ -match '^MemTotal:' }) -replace '\D+', '')
                $availKB = [long](($memInfo | Where-Object { $_ -match '^MemAvailable:' }) -replace '\D+', '')
                $ramTotalMB = [math]::Round($totalKB / 1024, 1)
                $ramUsedMB  = [math]::Round(($totalKB - $availKB) / 1024, 1)
            }

            # Reuse persistent CapturedValues hashtable (zero allocation per tick)
            $captured = $mon.CapturedValues

            $idleDelta  = $idle  - $mon.LastCpuIdle
            $totalDelta = $total - $mon.LastCpuTotal
            $cpuPercent = if ($totalDelta -gt 0) {
                [math]::Round((1 - ($idleDelta / $totalDelta)) * 100, 1)
            } else { 0 }

            $mon.LastCpuIdle  = $idle
            $mon.LastCpuTotal = $total

            # Reuse circular buffer sample in-place (zero allocation after first 30)
            $sample = $mon.Samples[$mon.WriteIndex]
            if ($null -eq $sample) {
                $mon.Samples[$mon.WriteIndex] = @{
                    Cpu    = [double]$cpuPercent
                    Ram    = [double]$ramUsedMB
                    RamMax = [double]$ramTotalMB
                }
            } else {
                $sample.Cpu    = [double]$cpuPercent
                $sample.Ram    = [double]$ramUsedMB
                $sample.RamMax = [double]$ramTotalMB
            }
            $mon.WriteIndex = ($mon.WriteIndex + 1) % 30
            if ($mon.Count -lt 30) { $mon.Count++ }

            # Store latest snapshot for fast reads
            $mon.LatestCpuPercent = [double]$cpuPercent
            $mon.LatestRamUsedMB  = [double]$ramUsedMB
            $mon.LatestRamTotalMB = [double]$ramTotalMB

            # Compute rolling averages from buffer
            $sumCpu = [double]0; $sumRam = [double]0
            for ($i = 0; $i -lt $mon.Count; $i++) {
                $s = $mon.Samples[$i]
                $sumCpu += $s.Cpu
                $sumRam += $s.Ram
            }
            $mon.AvgCpuPercent = [math]::Round($sumCpu / $mon.Count, 1)
            $mon.AvgRamUsedMB  = [math]::Round($sumRam / $mon.Count, 1)

            # Copy to persistent hashtable
            $captured.cpu    = $mon.LatestCpuPercent
            $captured.cpuAvg = $mon.AvgCpuPercent
            $captured.ram    = $mon.LatestRamUsedMB
            $captured.ramMax = $mon.LatestRamTotalMB
            $captured.ramAvg = $mon.AvgRamUsedMB

            # ── Merged HealthRefresher: every 2nd tick (~600s) ─────────────
            $mon.TickCount++
            if ($mon.TickCount % 2 -eq 0) {
                try {
                    $conn = $null; $cmd = $null; $reader = $null
                    try {
                        $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
                        $conn.Open()

                        # Active jobs count
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandText = "SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'"
                        $activeJobs = [int]$cmd.ExecuteScalar()
                        $cmd.Dispose(); $cmd = $null

                        # Job stats
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandText = @"
                            SELECT
                                COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0) AS totalCompleted,
                                COALESCE(SUM(CASE WHEN status = 'failed'    THEN 1 ELSE 0 END), 0) AS totalFailed,
                                COALESCE(AVG(CASE WHEN status = 'completed' AND duration_ms > 0 THEN duration_ms END), 0) AS avgDurationMs,
                                COALESCE(MIN(CASE WHEN status = 'completed' AND duration_ms > 0 THEN duration_ms END), 0) AS minDurationMs,
                                COALESCE(MAX(CASE WHEN status = 'completed' AND duration_ms > 0 THEN duration_ms END), 0) AS maxDurationMs,
                                MAX(completed_at) AS lastCompletedAt
                            FROM job_stats
"@
                        $reader = $cmd.ExecuteReader()

                        $hc.dbConnected = $true
                        $hc.activeJobs  = $activeJobs

                        if ($reader.Read()) {
                            $hc.totalCompleted  = [int]$reader['totalCompleted']
                            $hc.totalFailed     = [int]$reader['totalFailed']
                            $hc.avgDurationMs   = [math]::Round([double]$reader['avgDurationMs'])
                            $hc.minDurationMs   = [int]$reader['minDurationMs']
                            $hc.maxDurationMs   = [int]$reader['maxDurationMs']
                            $hc.lastCompletedAt = if ($reader.IsDBNull($reader.GetOrdinal('lastCompletedAt'))) { $null } else { $reader['lastCompletedAt'] }
                            $hc.avgDurationStr  = & $fmtDur ([int]$reader['avgDurationMs'])
                            $hc.minDurationStr  = & $fmtDur ([int]$reader['minDurationMs'])
                            $hc.maxDurationStr  = & $fmtDur ([int]$reader['maxDurationMs'])
                        }
                        $reader.Dispose(); $reader = $null
                    } finally {
                        if ($reader) { $reader.Dispose() }
                        if ($cmd)    { $cmd.Dispose() }
                        if ($conn)   { $conn.Dispose() }
                    }
                } catch {
                    $hc.dbConnected = $false
                }
            }

            # ── Merged MemoryLogger: every 6th tick (~1800s = 30min) ─────
            if ($mon.TickCount % 6 -eq 0) {
                try {
                    $now = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
                    $uptimeSecLog = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)
                    $gcInfo = [System.GC]::GetGCMemoryInfo()
                    $managedMB   = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 2)
                    $committedMB = [math]::Round($gcInfo.TotalCommittedBytes / 1MB, 2)
                    $fragMB      = [math]::Round($gcInfo.FragmentedBytes / 1MB, 2)
                    $gen0 = [System.GC]::CollectionCount(0)
                    $gen1 = [System.GC]::CollectionCount(1)
                    $gen2 = [System.GC]::CollectionCount(2)

                    $rssAnonKB = 0; $threads = 0
                    try {
                        $statusLines = [System.IO.File]::ReadAllLines('/proc/self/status')
                        foreach ($sLine in $statusLines) {
                            if ($sLine.StartsWith('RssAnon:')) { $rssAnonKB = [int]($sLine -replace '[^0-9]', '') }
                            if ($sLine.StartsWith('Threads:')) { $threads   = [int]($sLine -replace '[^0-9]', '') }
                        }
                        $statusLines = $null
                    } catch { }

                    $cgroupAnonMB  = 0; $cgroupTotalMB = 0
                    try {
                        $cgroupTotalMB = [math]::Round([long]([System.IO.File]::ReadAllText('/sys/fs/cgroup/memory.current').Trim()) / 1MB, 2)
                        $cgStat = [System.IO.File]::ReadAllLines('/sys/fs/cgroup/memory.stat')
                        foreach ($sLine in $cgStat) {
                            if ($sLine.StartsWith('anon ')) { $cgroupAnonMB = [math]::Round([long]($sLine -split ' ')[1] / 1MB, 2) }
                        }
                        $cgStat = $null
                    } catch { }

                    $logPath = '/tmp/memory.log'
                    $header  = 'timestamp,uptimeSec,managedMB,committedMB,fragMB,rssAnonKB,cgroupAnonMB,cgroupTotalMB,gen0,gen1,gen2,threads'
                    if (-not [System.IO.File]::Exists($logPath)) {
                        [System.IO.File]::WriteAllText($logPath, "$header`n")
                    }
                    $logLine = "$now,$uptimeSecLog,$managedMB,$committedMB,$fragMB,$rssAnonKB,$cgroupAnonMB,$cgroupTotalMB,$gen0,$gen1,$gen2,$threads"
                    [System.IO.File]::AppendAllText($logPath, "$logLine`n")

                    $gcInfo = $null

                    # Periodic memory compaction (~every 30 min).
                    # Defragments LOH and compacts Gen2 segments, releasing memory
                    # back to OS. Safe at this frequency — transient Gen0/Gen1
                    # objects have long since been collected naturally (unlike the
                    # old per-tick Invoke-PodeGC removed in Patch 3).
                    [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
                    [System.GC]::Collect(2, [System.GCCollectionMode]::Aggressive, $true, $true)
                } catch { }
            }

            # ── Pre-build /health JSON with reusable StringBuilder ────────
            $hc  = Get-PodeState -Name 'HealthCache'
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $uptimeSec = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)
            $ramPct    = if ($captured.ramMax -gt 0) { [math]::Round(($captured.ram / $captured.ramMax) * 100, 1) } else { [double]0 }
            $ramAvgPct = if ($captured.ramMax -gt 0) { [math]::Round(($captured.ramAvg / $captured.ramMax) * 100, 1) } else { [double]0 }
            $dbBool    = if ($hc.dbConnected) { 'true' } else { 'false' }
            $lastVal   = if ($hc.lastCompletedAt) { '"' + $hc.lastCompletedAt + '"' } else { 'null' }

            $sb = $mon.JsonBuilder
            $null = $sb.Clear()
            $null = $sb.Append('{"status":"ok","uptime":').Append($uptimeSec)
            $null = $sb.Append(',"dbConnected":').Append($dbBool)
            $null = $sb.Append(',"activeJobs":').Append([int]$hc.activeJobs)
            $null = $sb.Append(',"cpuPercent":').Append($captured.cpu.ToString($inv))
            $null = $sb.Append(',"cpuAvgPercent":').Append($captured.cpuAvg.ToString($inv))
            $null = $sb.Append(',"ramUsedMB":').Append($captured.ram.ToString($inv))
            $null = $sb.Append(',"ramTotalMB":').Append($captured.ramMax.ToString($inv))
            $null = $sb.Append(',"ramPercent":').Append($ramPct.ToString($inv))
            $null = $sb.Append(',"ramAvgMB":').Append($captured.ramAvg.ToString($inv))
            $null = $sb.Append(',"ramAvgPercent":').Append($ramAvgPct.ToString($inv))
            $null = $sb.Append(',"totalCompleted":').Append([int]$hc.totalCompleted)
            $null = $sb.Append(',"totalFailed":').Append([int]$hc.totalFailed)
            $null = $sb.Append(',"avgDurationMs":').Append([int]$hc.avgDurationMs)
            $null = $sb.Append(',"minDurationMs":').Append([int]$hc.minDurationMs)
            $null = $sb.Append(',"maxDurationMs":').Append([int]$hc.maxDurationMs)
            $null = $sb.Append(',"lastCompletedAt":').Append($lastVal).Append('}')

            $mon.HealthJson = $sb.ToString()
        } catch { }

        # Clear accumulated error records and null out temp vars so GC can reclaim.
        $Error.Clear()
        $cpuLine = $null; $fields = $null; $idle = $null; $total = $null
        $ramUsedMB = $null; $ramTotalMB = $null; $memInfo = $null
        $captured = $null; $hc = $null; $sb = $null; $inv = $null
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Middleware: API key validation on /api/* routes
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeMiddleware -Name 'ApiKeyAuth' -Route '/api/*' -ScriptBlock {
        # MEMORY FIX: Previously dot-sourced /app/lib/auth.ps1 on every /api/*
        # request — parsing the file, building AST, creating FunctionInfo objects
        # each time. Over days, these unreclaimable objects caused monotonic growth.
        # Now uses a pre-built ScriptBlock captured via $using: (zero allocations).
        $testKey = $using:TestApiKeyBlock

        if (-not (& $testKey $WebEvent.Request.Headers)) {
            $WebEvent.Response.StatusCode = 401
            # Generic message — never reveal whether the key is missing vs invalid
            Write-PodeJsonResponse -Value @{ error = 'Unauthorized.' }
            return $false
        }
        return $true
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET / — HTML stats dashboard (public)
    #
    # MEMORY-CRITICAL: Reads all data from PodeState caches. No dot-sourcing,
    # no Import-Module, no SQL. Data is refreshed every 5 min by the
    # ResourceSampler timer; JS polls /health to keep the page live.
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        $startTime = $using:SERVER_START_TIME

        # Read cached health data — no lock needed, HealthCache is [hashtable]::Synchronized
        $hcState = $using:_hcache
        $dbOkRead       = $hcState.dbConnected
        $activeJobsRead = $hcState.activeJobs
        $completedRead  = $hcState.totalCompleted
        $failedRead     = $hcState.totalFailed
        $lastRunRead    = $hcState.lastCompletedAt

        $dbOk       = $dbOkRead
        $activeJobs = $activeJobsRead
        $completed  = $completedRead
        $failed     = $failedRead
        $totalRuns  = $completed + $failed
        $lastRun    = if ($lastRunRead) { $lastRunRead } else { 'N/A' }
        $successRate = if ($totalRuns -gt 0) { [math]::Round(($completed / $totalRuns) * 100, 1) } else { 0 }

        $uptimeSec  = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)
        $uptimeStr  = '{0}d {1}h {2}m {3}s' -f [math]::Floor($uptimeSec / 86400),
                      [math]::Floor(($uptimeSec % 86400) / 3600),
                      [math]::Floor(($uptimeSec % 3600) / 60),
                      ($uptimeSec % 60)
        $dbStatus   = if ($dbOk) { '&#x2705; Connected' } else { '&#x274C; Disconnected' }

        # MEMORY FIX: Duration strings are now pre-computed by the HealthRefresher
        # timer and cached in HealthCache. Previously, 'function Format-Duration'
        # was defined HERE — creating a new FunctionInfo object on every page load.
        $avgStr = $hcState.avgDurationStr
        $minStr = $hcState.minDurationStr
        $maxStr = $hcState.maxDurationStr

        # ── Resource metrics from cached state (lock-free, single writer) ──
        $mon = Get-PodeState -Name 'ResourceMonitor'
        $resCpu    = $mon.LatestCpuPercent
        $resCpuAvg = $mon.AvgCpuPercent
        $resRam    = $mon.LatestRamUsedMB
        $resRamMax = $mon.LatestRamTotalMB
        $resRamAvg = $mon.AvgRamUsedMB
        $ramPercent    = if ($resRamMax -gt 0) { [math]::Round(($resRam / $resRamMax) * 100, 1) } else { 0 }
        $ramAvgPercent = if ($resRamMax -gt 0) { [math]::Round(($resRamAvg  / $resRamMax) * 100, 1) } else { 0 }
        $cpuColor  = if ($resCpu -ge 80) { 'status-error' } elseif ($resCpu -ge 50) { 'status-warn' } else { 'status-ok' }
        $cpuBar    = if ($resCpu -ge 80) { 'bar-red' }    elseif ($resCpu -ge 50) { 'bar-yellow' } else { 'bar-green' }
        $ramColor  = if ($ramPercent -ge 85) { 'status-error' }    elseif ($ramPercent -ge 60) { 'status-warn' } else { 'status-ok' }
        $ramBar    = if ($ramPercent -ge 85) { 'bar-red' }         elseif ($ramPercent -ge 60) { 'bar-yellow' } else { 'bar-green' }
        $ramOfStr  = if ($resRamMax -gt 0) { "of $($resRamMax) MB (${ramPercent}%)" } else { '(no limit set)' }
        $ramAvgSub = if ($resRamMax -gt 0) { "${ramAvgPercent}% &middot; Rolling 1-hour" } else { 'Rolling 1-hour window' }

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Maester API — Health Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d1117; color: #e6edf3; min-height: 100vh;
            display: flex; align-items: center; justify-content: center;
            padding: 2rem;
        }
        .dashboard { max-width: 720px; width: 100%; }
        .header {
            text-align: center; margin-bottom: 2rem;
        }
        .header h1 { font-size: 1.75rem; font-weight: 600; color: #58a6ff; }
        .header p { color: #8b949e; margin-top: 0.25rem; font-size: 0.9rem; }
        .grid {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem; margin-bottom: 1.5rem;
        }
        .card {
            background: #161b22; border: 1px solid #30363d; border-radius: 8px;
            padding: 1.25rem;
        }
        .card .label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: #8b949e; margin-bottom: 0.5rem; }
        .card .value { font-size: 1.5rem; font-weight: 600; }
        .card .sub   { font-size: 0.8rem; color: #8b949e; margin-top: 0.25rem; }
        .status-ok    { color: #3fb950; }
        .status-warn  { color: #d29922; }
        .status-error { color: #f85149; }
        .section-title { font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; color: #8b949e; margin-bottom: 0.75rem; font-weight: 600; }
        .bar-container { background: #21262d; border-radius: 4px; height: 8px; overflow: hidden; margin-top: 0.5rem; }
        .bar-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
        .bar-green  { background: #3fb950; }
        .bar-yellow { background: #d29922; }
        .bar-red    { background: #f85149; }
        .footer { text-align: center; margin-top: 2rem; font-size: 0.75rem; color: #484f58; }
        .footer a { color: #58a6ff; text-decoration: none; }
        .footer a:hover { text-decoration: underline; }
        .live-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: #3fb950; margin-right: 5px; animation: pulse 2s infinite; vertical-align: middle; }
        @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
        #last-updated { color: #484f58; font-size: 0.72rem; }
    </style>
</head>
<body>
<div class="dashboard">
    <div class="header">
        <h1>&#x1F6E1; Maester API</h1>
        <p>Health Dashboard &middot; <span class="live-dot"></span><span style="color:#3fb950;font-size:0.8rem">Live</span></p>
    </div>

    <div class="section-title">Server Status</div>
    <div class="grid">
        <div class="card">
            <div class="label">Status</div>
            <div class="value status-ok">Operational</div>
        </div>
        <div class="card">
            <div class="label">Uptime</div>
            <div class="value" id="uptime-val">$uptimeStr</div>
        </div>
        <div class="card">
            <div class="label">Database</div>
            <div class="value">$dbStatus</div>
        </div>
        <div class="card">
            <div class="label">Active Jobs</div>
            <div class="value $(if ($activeJobs -gt 0) { 'status-warn' } else { '' })" id="active-jobs-val">$activeJobs</div>
        </div>
    </div>

    <div class="section-title">Job Statistics (All Time)</div>
    <div class="grid">
        <div class="card">
            <div class="label">Total Runs</div>
            <div class="value" id="total-runs-val">$totalRuns</div>
            <div class="sub" id="total-runs-sub">$completed completed &middot; $failed failed</div>
            <div class="bar-container">
                <div class="bar-fill bar-green" id="success-rate-bar" style="width: ${successRate}%"></div>
            </div>
        </div>
        <div class="card">
            <div class="label">Success Rate</div>
            <div class="value $(if ($successRate -ge 80) { 'status-ok' } elseif ($successRate -ge 50) { 'status-warn' } else { 'status-error' })" id="success-rate-val">$successRate%</div>
        </div>
        <div class="card">
            <div class="label">Avg Duration</div>
            <div class="value" id="avg-dur-val">$avgStr</div>
            <div class="sub" id="avg-dur-sub">${avgMs}ms</div>
        </div>
        <div class="card">
            <div class="label">Min Duration</div>
            <div class="value" id="min-dur-val">$minStr</div>
            <div class="sub" id="min-dur-sub">${minMs}ms</div>
        </div>
        <div class="card">
            <div class="label">Max Duration</div>
            <div class="value" id="max-dur-val">$maxStr</div>
            <div class="sub" id="max-dur-sub">${maxMs}ms</div>
        </div>
        <div class="card">
            <div class="label">Last Run</div>
            <div class="value" id="last-run-val" style="font-size: 1rem;">$lastRun</div>
        </div>
    </div>

    <div class="section-title">Resource Usage</div>
    <div class="grid">
        <div class="card">
            <div class="label">CPU Current</div>
            <div class="value $cpuColor" id="cpu-current-val">$($resCpu)%</div>
            <div class="bar-container">
                <div class="bar-fill $cpuBar" id="cpu-current-bar" style="width: $($resCpu)%"></div>
            </div>
        </div>
        <div class="card">
            <div class="label">CPU Average</div>
            <div class="value" id="cpu-avg-val">$($resCpuAvg)%</div>
            <div class="sub">Rolling 1-hour window</div>
        </div>
        <div class="card">
            <div class="label">RAM Used</div>
            <div class="value $ramColor" id="ram-used-val">$($resRam) MB</div>
            <div class="sub" id="ram-used-sub">$ramOfStr</div>
            <div class="bar-container">
                <div class="bar-fill $ramBar" id="ram-used-bar" style="width: ${ramPercent}%"></div>
            </div>
        </div>
        <div class="card">
            <div class="label">RAM Average</div>
            <div class="value" id="ram-avg-val">$($resRamAvg) MB</div>
            <div class="sub" id="ram-avg-sub">$ramAvgSub</div>
        </div>
    </div>

    <div class="footer">
        <a href="/health">/health</a> (JSON) &middot; Maester API v1.1 &middot; <span id="last-updated">Connecting&hellip;</span>
    </div>
</div>
<script>
function statusCls(p, w, e) { return p >= e ? 'status-error' : p >= w ? 'status-warn' : 'status-ok'; }
function barCls(p, w, e) { return 'bar-fill ' + (p >= e ? 'bar-red' : p >= w ? 'bar-yellow' : 'bar-green'); }
function el(id) { return document.getElementById(id); }
function setText(id, t) { var e = el(id); if (e) e.textContent = t; }
function setHtml(id, h) { var e = el(id); if (e) e.innerHTML = h; }
function setBar(id, cls, pct) { var e = el(id); if (e) { e.className = cls; e.style.width = pct + '%'; } }
function setValueCls(id, cls) {
    var e = el(id); if (!e) return;
    e.className = e.className.replace(/status-\w+/g, '').trim();
    if (cls) e.className += ' ' + cls;
}
function fmtUptime(s) {
    return Math.floor(s/86400)+'d '+Math.floor((s%86400)/3600)+'h '+Math.floor((s%3600)/60)+'m '+(s%60)+'s';
}
function fmtDur(ms) {
    if (!ms || ms <= 0) return 'N/A';
    var s = Math.round(ms / 1000);
    if (s < 60) return s + 's';
    return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
}
function poll() {
    fetch('/health').then(function(r) { return r.json(); }).then(function(d) {
        setText('uptime-val', fmtUptime(d.uptime));
        setText('active-jobs-val', d.activeJobs);
        setValueCls('active-jobs-val', d.activeJobs > 0 ? 'status-warn' : '');

        setText('cpu-current-val', d.cpuPercent + '%');
        setValueCls('cpu-current-val', statusCls(d.cpuPercent, 50, 80));
        setBar('cpu-current-bar', barCls(d.cpuPercent, 50, 80), d.cpuPercent);
        setText('cpu-avg-val', d.cpuAvgPercent + '%');

        setText('ram-used-val', d.ramUsedMB + ' MB');
        setValueCls('ram-used-val', statusCls(d.ramPercent, 60, 85));
        setBar('ram-used-bar', barCls(d.ramPercent, 60, 85), d.ramPercent);
        setHtml('ram-used-sub', d.ramTotalMB > 0 ? ('of ' + d.ramTotalMB + ' MB (' + d.ramPercent + '%)') : '(no limit set)');
        setText('ram-avg-val', d.ramAvgMB + ' MB');
        setHtml('ram-avg-sub', d.ramTotalMB > 0 ? (d.ramAvgPercent + '% &middot; Rolling 1-hour') : 'Rolling 1-hour window');

        var totalRuns = (d.totalCompleted || 0) + (d.totalFailed || 0);
        var successRate = totalRuns > 0 ? Math.round((d.totalCompleted / totalRuns) * 1000) / 10 : 0;
        setText('total-runs-val', totalRuns);
        setHtml('total-runs-sub', (d.totalCompleted || 0) + ' completed &middot; ' + (d.totalFailed || 0) + ' failed');
        var srBar = el('success-rate-bar'); if (srBar) srBar.style.width = successRate + '%';
        setText('success-rate-val', successRate + '%');
        setValueCls('success-rate-val', totalRuns > 0 ? (successRate >= 80 ? 'status-ok' : successRate >= 50 ? 'status-warn' : 'status-error') : '');
        setText('avg-dur-val', fmtDur(d.avgDurationMs)); setText('avg-dur-sub', (d.avgDurationMs || 0) + 'ms');
        setText('min-dur-val', fmtDur(d.minDurationMs)); setText('min-dur-sub', (d.minDurationMs || 0) + 'ms');
        setText('max-dur-val', fmtDur(d.maxDurationMs)); setText('max-dur-sub', (d.maxDurationMs || 0) + 'ms');
        setText('last-run-val', d.lastCompletedAt || 'N/A');

        setText('last-updated', 'Updated ' + new Date().toLocaleTimeString());
    }).catch(function() { setText('last-updated', 'Poll failed — retrying…'); });
}
poll();
setInterval(poll, 300000);
</script>
</body>
</html>
"@

        Write-PodeHtmlResponse -Value $html
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET /health — Container health check (public, lightweight)
    #
    # MEMORY-CRITICAL: This endpoint is polled every 120 seconds by the
    # dashboard JS. It must NOT dot-source files, import modules, or run SQL.
    # All data is read from PodeState caches updated by the ResourceSampler
    # timer (every 120s).
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        # ZERO-ALLOCATION: Serve the pre-built JSON string directly.
        # The ResourceSampler timer (300s) rebuilds this string with fresh
        # CPU/RAM metrics + cached DB stats. No hashtable creation, no
        # ConvertTo-Json or Get-PodeState per request.
        Write-PodeTextResponse -Value ($using:_resmon).HealthJson -ContentType 'application/json'
    }

    # GET /diag — GC + native memory diagnostics (memory investigation)
    Add-PodeRoute -Method Get -Path '/diag' -ScriptBlock {
        $info = [System.GC]::GetGCMemoryInfo()
        $diag = [ordered]@{
            managedHeapMB   = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 2)
            gen0Collections = [System.GC]::CollectionCount(0)
            gen1Collections = [System.GC]::CollectionCount(1)
            gen2Collections = [System.GC]::CollectionCount(2)
            heapSizeMB      = [math]::Round($info.HeapSizeBytes / 1MB, 2)
            committedMB     = [math]::Round($info.TotalCommittedBytes / 1MB, 2)
            fragmentedMB    = [math]::Round($info.FragmentedBytes / 1MB, 2)
            pinnedObjects   = $info.PinnedObjectsCount
            finalizePending = $info.FinalizationPendingCount
            pauseDurationsMs = @($info.PauseDurations | ForEach-Object { [math]::Round($_.TotalMilliseconds, 1) })
        }

        # Native memory from /proc/self/status (RssAnon = heap + JIT + PS metadata)
        try {
            $statusLines = [System.IO.File]::ReadAllLines('/proc/self/status')
            foreach ($line in $statusLines) {
                if ($line.StartsWith('VmRSS:'))    { $diag.vmRssKB    = [int]($line -replace '[^0-9]', '') }
                if ($line.StartsWith('RssAnon:'))   { $diag.rssAnonKB  = [int]($line -replace '[^0-9]', '') }
                if ($line.StartsWith('RssFile:'))    { $diag.rssFileKB  = [int]($line -replace '[^0-9]', '') }
                if ($line.StartsWith('RssShmem:'))   { $diag.rssShmemKB = [int]($line -replace '[^0-9]', '') }
                if ($line.StartsWith('Threads:'))    { $diag.threads    = [int]($line -replace '[^0-9]', '') }
            }
            $statusLines = $null
        } catch { }

        # Cgroup memory breakdown (container-level)
        try {
            $diag.cgroupTotalMB = [math]::Round([long]([System.IO.File]::ReadAllText('/sys/fs/cgroup/memory.current').Trim()) / 1MB, 2)
            $cgStat = [System.IO.File]::ReadAllLines('/sys/fs/cgroup/memory.stat')
            foreach ($line in $cgStat) {
                if ($line.StartsWith('anon '))  { $diag.cgroupAnonMB = [math]::Round([long]($line -split ' ')[1] / 1MB, 2) }
                if ($line.StartsWith('file '))  { $diag.cgroupFileMB = [math]::Round([long]($line -split ' ')[1] / 1MB, 2) }
                if ($line.StartsWith('shmem ')) { $diag.cgroupShmemMB = [math]::Round([long]($line -split ' ')[1] / 1MB, 2) }
            }
            $cgStat = $null
        } catch { }

        Write-PodeJsonResponse -Value $diag
    }

    # GET /diag/log — Retrieve the periodic memory log CSV
    Add-PodeRoute -Method Get -Path '/diag/log' -ScriptBlock {
        $logPath = '/tmp/memory.log'
        if ([System.IO.File]::Exists($logPath)) {
            $content = [System.IO.File]::ReadAllText($logPath)
            Write-PodeTextResponse -Value $content -ContentType 'text/csv'
        } else {
            Write-PodeTextResponse -Value 'No memory log yet (first entry after 30 min).' -ContentType 'text/plain'
        }
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
        $recordCompletion = $using:RecordJobCompletionBlock

        # ── Validate jobId ────────────────────────────────────────────────────
        $jobId = $WebEvent.Query['jobId']
        if (-not $jobId) {
            $WebEvent.Response.StatusCode = 400
            Write-PodeJsonResponse -Value @{ error = 'Missing required query parameter: jobId' }
            return
        }
        # Validate jobId format (32-char hex GUID without dashes)
        if ($jobId -notmatch '^[0-9a-fA-F]{32}$') {
            $WebEvent.Response.StatusCode = 400
            Write-PodeJsonResponse -Value @{ error = 'Invalid jobId format.' }
            return
        }

        # ── Fetch from SQLite (raw ADO.NET) ──────────────────────────────────
        $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
        $job = $null
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = 'SELECT * FROM jobs WHERE job_id = @jobId'
            $null = $cmd.Parameters.AddWithValue('@jobId', $jobId)
            $reader = $cmd.ExecuteReader()
            if ($reader.Read()) {
                $job = [PSCustomObject]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $val = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                    $job | Add-Member -NotePropertyName $reader.GetName($i) -NotePropertyValue $val
                }
            }
            $reader.Dispose(); $cmd.Dispose()
        } finally { $conn.Dispose() }

        if (-not $job) {
            $WebEvent.Response.StatusCode = 404
            Write-PodeJsonResponse -Value ([ordered]@{ error = 'Job not found.' })
            return
        }

        # ── Stale job detection ───────────────────────────────────────────────
        if ($job.status -eq 'running' -and $job.created_at) {
            try {
                $created = [datetime]::Parse($job.created_at).ToUniversalTime()
                $elapsed = ([datetime]::UtcNow - $created).TotalMinutes
                if ($elapsed -gt $staleMinutes) {
                    $now = [datetime]::UtcNow.ToString('o')
                    $conn2 = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
                    try {
                        $conn2.Open()
                        # Update stale job
                        $cmd2 = $conn2.CreateCommand()
                        $cmd2.CommandText = "UPDATE jobs SET status = 'failed', error = @error, updated_at = @now WHERE job_id = @jobId AND status = 'running'"
                        $null = $cmd2.Parameters.AddWithValue('@jobId', $jobId)
                        $null = $cmd2.Parameters.AddWithValue('@error', "Job timed out after $([math]::Round($elapsed)) minutes.")
                        $null = $cmd2.Parameters.AddWithValue('@now', $now)
                        $null = $cmd2.ExecuteNonQuery()
                        $cmd2.Dispose()
                        # Re-read the updated row
                        $cmd3 = $conn2.CreateCommand()
                        $cmd3.CommandText = 'SELECT * FROM jobs WHERE job_id = @jobId'
                        $null = $cmd3.Parameters.AddWithValue('@jobId', $jobId)
                        $reader3 = $cmd3.ExecuteReader()
                        if ($reader3.Read()) {
                            $job = [PSCustomObject]@{}
                            for ($i = 0; $i -lt $reader3.FieldCount; $i++) {
                                $val = if ($reader3.IsDBNull($i)) { $null } else { $reader3.GetValue($i) }
                                $job | Add-Member -NotePropertyName $reader3.GetName($i) -NotePropertyValue $val
                            }
                        }
                        $reader3.Dispose(); $cmd3.Dispose()
                    } finally { $conn2.Dispose() }
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
            # Persist stats before deleting the job row
            try {
                & $recordCompletion $dbPath $job.job_id $job.status ([int]($job.duration_ms)) $job.suites
            } catch { }

            $connDel = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
            try {
                $connDel.Open()
                $cmdDel = $connDel.CreateCommand()
                $cmdDel.CommandText = 'DELETE FROM jobs WHERE job_id = @jobId'
                $null = $cmdDel.Parameters.AddWithValue('@jobId', $jobId)
                $null = $cmdDel.ExecuteNonQuery()
                $cmdDel.Dispose()
            } finally { $connDel.Dispose() }

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
        $getBearerToken    = $using:GetBearerTokenBlock
        $testTenantId      = $using:TestValidTenantIdBlock

        # ── 0. Request size guard (max 64KB body) ─────────────────────────────
        $contentLength = $WebEvent.Request.Headers['Content-Length']
        if ($contentLength -and [long]$contentLength -gt 65536) {
            $WebEvent.Response.StatusCode = 413
            Write-PodeJsonResponse -Value @{ error = 'Request body too large.' }
            return
        }

        # ── 1. Extract bearer token (MSAL workspace token — proxy auth) ─────────────
        $rawToken = & $getBearerToken $WebEvent.Request.Headers
        if (-not $rawToken) {
            $WebEvent.Response.StatusCode = 401
            Write-PodeJsonResponse -Value @{
                error = 'Authentication required.'
            }
            return
        }

        # ── 1a. Extract optional app-registration credentials ──────────────────
        # The runner uses these to acquire all service tokens (Exchange, IPPS,
        # Teams, Azure) itself via client_credentials grant.
        $maesterClientId     = $WebEvent.Request.Headers['X-Maester-Client-Id']
        $maesterClientSecret = $WebEvent.Request.Headers['X-Maester-Client-Secret']

        # ── 2. Parse and validate request body ───────────────────────────────
        try {
            $body           = $WebEvent.Data

            # Validate suites against allowlist
            $allowedSuites = @('maester','cisa','eidsca','orca','cis','xspm')
            $suites         = if ($body.suites) {
                @($body.suites | Where-Object { $_ -in $allowedSuites })
            } else { @('maester','cisa','eidsca','orca','cis') }
            if ($suites.Count -eq 0) { $suites = @('maester','cisa','eidsca','orca','cis') }

            # Validate severities against allowlist
            $allowedSeverities = @('Critical','High','Medium','Low','Info')
            $severities     = if ($body.severity) {
                @($body.severity | Where-Object { $_ -in $allowedSeverities })
            } else { @('Critical','High','Medium','Low','Info') }
            if ($severities.Count -eq 0) { $severities = @('Critical','High','Medium','Low','Info') }

            $extraTags      = if ($body.tags) {
                # Sanitize tags: alphanumeric, dots, hyphens, colons only
                @($body.tags | ForEach-Object { $_ -replace '[^A-Za-z0-9.:\-_]', '' } | Where-Object { $_ })
            } else { @() }
            $incLongRunning = if ($null -ne $body.includeLongRunning) { [bool]$body.includeLongRunning } else { $true  }
            # Default Preview to $true — many EIDSCA tests are tagged Preview and excluding
            # them by default was causing the majority of skipped results.
            $incPreview     = if ($null -ne $body.includePreview)     { [bool]$body.includePreview }     else { $true  }

            # Validate tenantId format (must be a valid GUID if provided)
            $tenantId = ''
            if ($body.tenantId) {
                $tenantId = [string]$body.tenantId
                if (-not (& $testTenantId $tenantId)) {
                    $WebEvent.Response.StatusCode = 400
                    Write-PodeJsonResponse -Value @{ error = 'Invalid tenantId format. Must be a valid GUID.' }
                    return
                }
            }

        } catch {
            $WebEvent.Response.StatusCode = 400
            Write-PodeJsonResponse -Value ([ordered]@{ error = 'Invalid request body.' })
            return
        }

        # ── 3. Concurrency guard (per-tenant) ────────────────────────────────
        # One run at a time per tenant. Different tenants may run in parallel.
        $connGuard = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
        $runningCount = 0
        try {
            $connGuard.Open()
            $cmdGuard = $connGuard.CreateCommand()
            $cmdGuard.CommandText = "SELECT COUNT(*) FROM jobs WHERE status = 'running' AND tenant_id = @tenantId"
            $null = $cmdGuard.Parameters.AddWithValue('@tenantId', $tenantId)
            $runningCount = [int]$cmdGuard.ExecuteScalar()
            $cmdGuard.Dispose()
        } finally { $connGuard.Dispose() }

        if ($runningCount -ge $maxConcurrent) {
            $WebEvent.Response.StatusCode = 409
            Write-PodeJsonResponse -Value @{
                error = "A Maester test run is already in progress for this tenant. Running two concurrent scans against the same tenant causes Graph API throttling and inconsistent results. Please wait for the current run to complete."
            }
            return
        }

        # ── 4. Create job in SQLite ──────────────────────────────────────────
        $jobId = [guid]::NewGuid().ToString('N')
        $now   = [datetime]::UtcNow.ToString('o')

        $connIns = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
        try {
            $connIns.Open()
            $cmdIns = $connIns.CreateCommand()
            $cmdIns.CommandText = "INSERT INTO jobs (job_id, status, created_at, updated_at, suites, severity, tenant_id) VALUES (@jobId, 'running', @now, @now, @suites, @severity, @tenantId)"
            $null = $cmdIns.Parameters.AddWithValue('@jobId', $jobId)
            $null = $cmdIns.Parameters.AddWithValue('@now', $now)
            $null = $cmdIns.Parameters.AddWithValue('@suites', ($suites | ConvertTo-Json -Compress))
            $null = $cmdIns.Parameters.AddWithValue('@severity', ($severities | ConvertTo-Json -Compress))
            $null = $cmdIns.Parameters.AddWithValue('@tenantId', $tenantId)
            $null = $cmdIns.ExecuteNonQuery()
            $cmdIns.Dispose()
        } finally { $connIns.Dispose() }

        # ── 5. Cleanup expired jobs ──────────────────────────────────────────
        try {
            $hardCutoff      = [datetime]::UtcNow.AddHours(-2).ToString('o')
            $completedCutoff = [datetime]::UtcNow.AddMinutes(-10).ToString('o')

            $connClean = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
            try {
                $connClean.Open()
                $cmdC1 = $connClean.CreateCommand()
                $cmdC1.CommandText = 'DELETE FROM jobs WHERE created_at < @cutoff'
                $null = $cmdC1.Parameters.AddWithValue('@cutoff', $hardCutoff)
                $null = $cmdC1.ExecuteNonQuery()
                $cmdC1.Dispose()

                $cmdC2 = $connClean.CreateCommand()
                $cmdC2.CommandText = "DELETE FROM jobs WHERE status IN ('completed', 'failed') AND updated_at < @cutoff"
                $null = $cmdC2.Parameters.AddWithValue('@cutoff', $completedCutoff)
                $null = $cmdC2.ExecuteNonQuery()
                $cmdC2.Dispose()
            } finally { $connClean.Dispose() }
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

        try {
            # 1. Mark stale running jobs as failed
            $cutoff = [datetime]::UtcNow.AddMinutes(-$staleMinutes).ToString('o')
            $now    = [datetime]::UtcNow.ToString('o')
            $conn = $null; $cmd = $null
            try {
                $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$dbPath")
                $conn.Open()

                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "UPDATE jobs SET status = 'failed', error = 'Job timed out (cleanup timer). Container may have restarted.', updated_at = @now WHERE status = 'running' AND created_at < @cutoff"
                $null = $cmd.Parameters.AddWithValue('@cutoff', $cutoff)
                $null = $cmd.Parameters.AddWithValue('@now',    $now)
                $null = $cmd.ExecuteNonQuery()
                $cmd.Dispose(); $cmd = $null

                # 2. Delete expired jobs (>2h old)
                $hardCutoff = [datetime]::UtcNow.AddHours(-2).ToString('o')
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = 'DELETE FROM jobs WHERE created_at < @cutoff'
                $null = $cmd.Parameters.AddWithValue('@cutoff', $hardCutoff)
                $null = $cmd.ExecuteNonQuery()
                $cmd.Dispose(); $cmd = $null

                # 4. Reclaim SQLite space
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = 'PRAGMA incremental_vacuum;'
                $null = $cmd.ExecuteNonQuery()
            } finally {
                if ($cmd)  { $cmd.Dispose() }
                if ($conn) { $conn.Dispose() }
            }

            # 3. Cleanup completed PowerShell thread jobs
            Get-Job | Where-Object { $_.State -in @('Completed', 'Failed') } |
                Remove-Job -Force -ErrorAction SilentlyContinue
        }
        catch { }

        # Null out temporary SQL result variables before GC
        $cutoff = $null; $now = $null; $hardCutoff = $null
    }
}
