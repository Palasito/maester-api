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
    # Resource monitoring: CPU + RAM sampling every 30 seconds
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
        Samples      = [System.Collections.ArrayList]::new()
        LastCpuIdle  = $initCpuIdle
        LastCpuTotal = $initCpuTotal
    }

    Add-PodeTimer -Name 'ResourceSampler' -Interval 30 -ScriptBlock {
        try {
            # ── CPU from /proc/stat ──────────────────────────────────────
            $cpuLine = (Get-Content /proc/stat -TotalCount 1) -replace '^cpu\s+', ''
            $fields  = $cpuLine -split '\s+' | ForEach-Object { [long]$_ }
            $idle    = [long]$fields[3] + [long]$fields[4]
            $total   = ($fields | Measure-Object -Sum).Sum

            # ── RAM from cgroup (v2 → v1 → /proc/meminfo fallback) ──────
            $ramUsedMB = 0; $ramTotalMB = 0
            if (Test-Path '/sys/fs/cgroup/memory.current') {
                # cgroup v2
                $ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory.current') / 1MB, 1)
                $maxRaw     = (Get-Content '/sys/fs/cgroup/memory.max').Trim()
                $ramTotalMB = if ($maxRaw -eq 'max') { 0 } else { [math]::Round([long]$maxRaw / 1MB, 1) }
            }
            elseif (Test-Path '/sys/fs/cgroup/memory/memory.usage_in_bytes') {
                # cgroup v1
                $ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory/memory.usage_in_bytes') / 1MB, 1)
                $limitRaw   = (Get-Content '/sys/fs/cgroup/memory/memory.limit_in_bytes').Trim()
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

            Lock-PodeObject -Name 'ResourceLock' -ScriptBlock {
                $mon = Get-PodeState -Name 'ResourceMonitor'

                $idleDelta  = $idle  - $mon.LastCpuIdle
                $totalDelta = $total - $mon.LastCpuTotal
                $cpuPercent = if ($totalDelta -gt 0) {
                    [math]::Round((1 - ($idleDelta / $totalDelta)) * 100, 1)
                } else { 0 }

                $mon.LastCpuIdle  = $idle
                $mon.LastCpuTotal = $total

                $mon.Samples.Add([PSCustomObject]@{
                    CpuPercent = [double]$cpuPercent
                    RamUsedMB  = [double]$ramUsedMB
                    RamTotalMB = [double]$ramTotalMB
                }) | Out-Null

                # Keep last 120 samples (1 hour at 30s intervals)
                while ($mon.Samples.Count -gt 120) { $mon.Samples.RemoveAt(0) }
            }
        } catch { }
    }

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
    # GET / — HTML stats dashboard (no auth)
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        $dbPath    = $using:DB_PATH
        $startTime = $using:SERVER_START_TIME

        # Re-source db helpers (Pode runspaces don't share parent scope)
        . /app/lib/db.ps1

        $dbOk       = $false
        $activeJobs = 0
        $stats      = $null
        try {
            Import-Module PSSQLite -ErrorAction SilentlyContinue
            $row = Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'"
            $activeJobs = [int]$row.cnt
            $dbOk = $true
            $stats = Get-JobStats -DbPath $dbPath
        } catch { }

        $uptimeSec    = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)
        $uptimeStr    = '{0}d {1}h {2}m {3}s' -f [math]::Floor($uptimeSec / 86400),
                        [math]::Floor(($uptimeSec % 86400) / 3600),
                        [math]::Floor(($uptimeSec % 3600) / 60),
                        ($uptimeSec % 60)
        $dbStatus     = if ($dbOk) { '&#x2705; Connected' } else { '&#x274C; Disconnected' }
        $completed    = if ($stats) { $stats.totalCompleted } else { 0 }
        $failed       = if ($stats) { $stats.totalFailed }    else { 0 }
        $totalRuns    = $completed + $failed
        $avgMs        = if ($stats) { $stats.avgDurationMs }  else { 0 }
        $minMs        = if ($stats) { $stats.minDurationMs }  else { 0 }
        $maxMs        = if ($stats) { $stats.maxDurationMs }  else { 0 }
        $lastRun      = if ($stats -and $stats.lastCompletedAt) { $stats.lastCompletedAt } else { 'N/A' }
        $successRate  = if ($totalRuns -gt 0) { [math]::Round(($completed / $totalRuns) * 100, 1) } else { 0 }

        # Format durations as human-readable
        function Format-Duration([int]$ms) {
            if ($ms -le 0) { return 'N/A' }
            $totalSec = [math]::Round($ms / 1000)
            if ($totalSec -lt 60) { return "${totalSec}s" }
            $m = [math]::Floor($totalSec / 60)
            $s = $totalSec % 60
            return "${m}m ${s}s"
        }
        $avgStr = Format-Duration $avgMs
        $minStr = Format-Duration $minMs
        $maxStr = Format-Duration $maxMs

        # ── Resource metrics ──────────────────────────────────────────────────
        $res = @{ cpuPercent = 0; cpuAvgPercent = 0; ramUsedMB = 0; ramTotalMB = 0; ramAvgMB = 0 }
        try {
            if (Test-Path '/sys/fs/cgroup/memory.current') {
                $res.ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory.current') / 1MB, 1)
                $maxRaw         = (Get-Content '/sys/fs/cgroup/memory.max').Trim()
                $res.ramTotalMB = if ($maxRaw -eq 'max') { 0 } else { [math]::Round([long]$maxRaw / 1MB, 1) }
            }
            elseif (Test-Path '/sys/fs/cgroup/memory/memory.usage_in_bytes') {
                $res.ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory/memory.usage_in_bytes') / 1MB, 1)
                $limitRaw       = (Get-Content '/sys/fs/cgroup/memory/memory.limit_in_bytes').Trim()
                $res.ramTotalMB = if ([long]$limitRaw -gt 1TB) { 0 } else { [math]::Round([long]$limitRaw / 1MB, 1) }
            }
            else {
                $memInfo = Get-Content /proc/meminfo -ErrorAction SilentlyContinue
                $totalKB = [long](($memInfo | Where-Object { $_ -match '^MemTotal:' }) -replace '\D+', '')
                $availKB = [long](($memInfo | Where-Object { $_ -match '^MemAvailable:' }) -replace '\D+', '')
                $res.ramTotalMB = [math]::Round($totalKB / 1024, 1)
                $res.ramUsedMB  = [math]::Round(($totalKB - $availKB) / 1024, 1)
            }
            Lock-PodeObject -Name 'ResourceLock' -ScriptBlock {
                $mon = Get-PodeState -Name 'ResourceMonitor'
                if ($mon -and $mon.Samples.Count -gt 0) {
                    $res.cpuPercent    = $mon.Samples[-1].CpuPercent
                    $res.cpuAvgPercent = [math]::Round(($mon.Samples | Measure-Object -Property CpuPercent -Average).Average, 1)
                    $res.ramAvgMB      = [math]::Round(($mon.Samples | Measure-Object -Property RamUsedMB  -Average).Average, 1)
                }
            }
        } catch { }
        $ramPercent    = if ($res.ramTotalMB -gt 0) { [math]::Round(($res.ramUsedMB / $res.ramTotalMB) * 100, 1) } else { 0 }
        $ramAvgPercent = if ($res.ramTotalMB -gt 0) { [math]::Round(($res.ramAvgMB  / $res.ramTotalMB) * 100, 1) } else { 0 }
        $cpuColor  = if ($res.cpuPercent -ge 80) { 'status-error' } elseif ($res.cpuPercent -ge 50) { 'status-warn' } else { 'status-ok' }
        $cpuBar    = if ($res.cpuPercent -ge 80) { 'bar-red' }    elseif ($res.cpuPercent -ge 50) { 'bar-yellow' } else { 'bar-green' }
        $ramColor  = if ($ramPercent -ge 85) { 'status-error' }    elseif ($ramPercent -ge 60) { 'status-warn' } else { 'status-ok' }
        $ramBar    = if ($ramPercent -ge 85) { 'bar-red' }         elseif ($ramPercent -ge 60) { 'bar-yellow' } else { 'bar-green' }
        $ramOfStr  = if ($res.ramTotalMB -gt 0) { "of $($res.ramTotalMB) MB (${ramPercent}%)" } else { '(no limit set)' }
        $ramAvgSub = if ($res.ramTotalMB -gt 0) { "${ramAvgPercent}% &middot; Rolling 1-hour" } else { 'Rolling 1-hour window' }

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
            <div class="value $cpuColor" id="cpu-current-val">$($res.cpuPercent)%</div>
            <div class="bar-container">
                <div class="bar-fill $cpuBar" id="cpu-current-bar" style="width: $($res.cpuPercent)%"></div>
            </div>
        </div>
        <div class="card">
            <div class="label">CPU Average</div>
            <div class="value" id="cpu-avg-val">$($res.cpuAvgPercent)%</div>
            <div class="sub">Rolling 1-hour window</div>
        </div>
        <div class="card">
            <div class="label">RAM Used</div>
            <div class="value $ramColor" id="ram-used-val">$($res.ramUsedMB) MB</div>
            <div class="sub" id="ram-used-sub">$ramOfStr</div>
            <div class="bar-container">
                <div class="bar-fill $ramBar" id="ram-used-bar" style="width: ${ramPercent}%"></div>
            </div>
        </div>
        <div class="card">
            <div class="label">RAM Average</div>
            <div class="value" id="ram-avg-val">$($res.ramAvgMB) MB</div>
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
setInterval(poll, 1000);
</script>
</body>
</html>
"@

        Write-PodeHtmlResponse -Value $html
    }

    # ══════════════════════════════════════════════════════════════════════════
    # GET /health — Container health check (no auth)
    # ══════════════════════════════════════════════════════════════════════════
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        $dbPath    = $using:DB_PATH
        $startTime = $using:SERVER_START_TIME

        # Re-source db helpers (Pode runspaces don't share parent scope)
        . /app/lib/db.ps1

        $dbOk       = $false
        $activeJobs = 0
        $stats      = $null
        try {
            Import-Module PSSQLite -ErrorAction SilentlyContinue
            $row = Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'"
            $activeJobs = [int]$row.cnt
            $dbOk = $true
            $stats = Get-JobStats -DbPath $dbPath
        } catch { }

        # ── Resource metrics (live RAM + averages from sampler) ───────────
        $res = @{ cpuPercent = 0; cpuAvgPercent = 0; ramUsedMB = 0; ramTotalMB = 0; ramAvgMB = 0 }
        try {
            # Live RAM reading
            if (Test-Path '/sys/fs/cgroup/memory.current') {
                $res.ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory.current') / 1MB, 1)
                $maxRaw         = (Get-Content '/sys/fs/cgroup/memory.max').Trim()
                $res.ramTotalMB = if ($maxRaw -eq 'max') { 0 } else { [math]::Round([long]$maxRaw / 1MB, 1) }
            }
            elseif (Test-Path '/sys/fs/cgroup/memory/memory.usage_in_bytes') {
                $res.ramUsedMB  = [math]::Round([long](Get-Content '/sys/fs/cgroup/memory/memory.usage_in_bytes') / 1MB, 1)
                $limitRaw       = (Get-Content '/sys/fs/cgroup/memory/memory.limit_in_bytes').Trim()
                $res.ramTotalMB = if ([long]$limitRaw -gt 1TB) { 0 } else { [math]::Round([long]$limitRaw / 1MB, 1) }
            }
            else {
                $memInfo = Get-Content /proc/meminfo -ErrorAction SilentlyContinue
                $totalKB = [long](($memInfo | Where-Object { $_ -match '^MemTotal:' }) -replace '\D+', '')
                $availKB = [long](($memInfo | Where-Object { $_ -match '^MemAvailable:' }) -replace '\D+', '')
                $res.ramTotalMB = [math]::Round($totalKB / 1024, 1)
                $res.ramUsedMB  = [math]::Round(($totalKB - $availKB) / 1024, 1)
            }

            # CPU current + averages from ResourceMonitor state
            Lock-PodeObject -Name 'ResourceLock' -ScriptBlock {
                $mon = Get-PodeState -Name 'ResourceMonitor'
                if ($mon -and $mon.Samples.Count -gt 0) {
                    $res.cpuPercent    = $mon.Samples[-1].CpuPercent
                    $res.cpuAvgPercent = [math]::Round(($mon.Samples | Measure-Object -Property CpuPercent -Average).Average, 1)
                    $res.ramAvgMB      = [math]::Round(($mon.Samples | Measure-Object -Property RamUsedMB  -Average).Average, 1)
                }
            }
        } catch { }

        $ramPercent    = if ($res.ramTotalMB -gt 0) { [math]::Round(($res.ramUsedMB / $res.ramTotalMB) * 100, 1) } else { 0 }
        $ramAvgPercent = if ($res.ramTotalMB -gt 0) { [math]::Round(($res.ramAvgMB  / $res.ramTotalMB) * 100, 1) } else { 0 }
        $uptimeSec     = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds)

        $response = [ordered]@{
            status          = 'ok'
            uptime          = $uptimeSec
            dbConnected     = $dbOk
            activeJobs      = $activeJobs
            cpuPercent      = $res.cpuPercent
            cpuAvgPercent   = $res.cpuAvgPercent
            ramUsedMB       = $res.ramUsedMB
            ramTotalMB      = $res.ramTotalMB
            ramPercent      = $ramPercent
            ramAvgMB        = $res.ramAvgMB
            ramAvgPercent   = $ramAvgPercent
            totalCompleted  = if ($stats) { $stats.totalCompleted } else { 0 }
            totalFailed     = if ($stats) { $stats.totalFailed }    else { 0 }
            avgDurationMs   = if ($stats) { $stats.avgDurationMs }  else { 0 }
            minDurationMs   = if ($stats) { $stats.minDurationMs }  else { 0 }
            maxDurationMs   = if ($stats) { $stats.maxDurationMs }  else { 0 }
            lastCompletedAt = if ($stats) { $stats.lastCompletedAt } else { $null }
        }

        Write-PodeJsonResponse -Value $response
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
        # Re-source db helpers (Pode runspaces don't share parent scope)
        . /app/lib/db.ps1

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
            # Persist stats before deleting the job row
            try {
                Record-JobCompletion -DbPath $dbPath `
                    -JobId       $job.job_id `
                    -Status      $job.status `
                    -DurationMs  ([int]($job.duration_ms)) `
                    -Suites      $job.suites
            } catch { }

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

        # ── 1. Extract bearer token (MSAL workspace token — proxy auth) ─────────────
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
