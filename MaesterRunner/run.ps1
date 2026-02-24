# MaesterRunner Azure Function (PowerShell)
# Async job pattern:  POST starts a background job → returns jobId immediately.
#                     GET polls job status → returns results when done.
#
# POST /api/maester
#   Body: { suites, severity?, tags?, includeLongRunning?, includePreview? }
#   Auth: Authorization: Bearer <token>
#   Response (202): { jobId, status: "running", createdAt }
#
# GET /api/maester?jobId=<id>
#   Response (200): { jobId, status, createdAt, updatedAt, result?, error? }
#
# Job state is persisted as JSON files under /home/maester-jobs/ so it survives
# function host restarts and can be polled by follow-up GET requests.

using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

# ─── Constants ────────────────────────────────────────────────────────────────
# /home/ is persistent Azure Files storage on App Service; falls back to temp.
$JOBS_DIR = if (Test-Path '/home') { '/home/maester-jobs' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'maester-jobs' }
$JOB_MAX_AGE_HOURS              = 2   # Hard upper bound — delete any file older than this
$JOB_STALE_MINUTES              = 30  # Mark a "running" job as timed-out after this
$JOB_COMPLETED_TIMEOUT_MINUTES  = 10  # Delete completed/failed files unread after this

# Ensure jobs directory exists
if (-not (Test-Path $JOBS_DIR)) {
    $null = New-Item -ItemType Directory -Path $JOBS_DIR -Force
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-JobFile {
    param([string]$Path, [hashtable]$Data)
    $json = $Data | ConvertTo-Json -Depth 12 -Compress
    # Atomic write: temp file → rename (rename is atomic on Linux within same FS)
    $tmpPath = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json)
    Move-Item -Path $tmpPath -Destination $Path -Force
}

function Read-JobFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try   { Get-Content -Path $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE: GET — Poll job status
# ═══════════════════════════════════════════════════════════════════════════════

if ($Request.Method -eq 'GET') {
    $jobId = $Request.Query.jobId
    if (-not $jobId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = '{"error":"Missing required query parameter: jobId"}'
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $jobFile = Join-Path $JOBS_DIR "$jobId.json"
    $jobData = Read-JobFile -Path $jobFile

    if (-not $jobData) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = ([ordered]@{ error = "Job not found: $jobId" } | ConvertTo-Json -Compress)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # Stale job detection — if "running" longer than threshold, the host may
    # have restarted mid-run and the thread job was lost.
    if ($jobData.status -eq 'running' -and $jobData.createdAt) {
        try {
            $created = [datetime]::Parse($jobData.createdAt).ToUniversalTime()
            $elapsed = ([datetime]::UtcNow - $created).TotalMinutes
            if ($elapsed -gt $JOB_STALE_MINUTES) {
                $jobData.status    = 'failed'
                $jobData.error     = "Job timed out after $([math]::Round($elapsed)) minutes. The function host may have restarted."
                $jobData.updatedAt = [datetime]::UtcNow.ToString('o')
                # Persist the failure so subsequent polls don't re-compute
                $hash = [ordered]@{}
                foreach ($prop in $jobData.PSObject.Properties) { $hash[$prop.Name] = $prop.Value }
                Write-JobFile -Path $jobFile -Data $hash
            }
        } catch { }
    }

    # Delete the job file immediately if the run has reached a terminal state.
    # Once the caller has received the result there is no reason to keep it on disk.
    if ($jobData.status -in @('completed', 'failed')) {
        Remove-Item -Path $jobFile -Force -ErrorAction SilentlyContinue
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($jobData | ConvertTo-Json -Depth 12 -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE: POST — Start a new Maester test run
# ═══════════════════════════════════════════════════════════════════════════════

if ($Request.Method -ne 'POST') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::MethodNotAllowed
        Body       = {error="Method not allowed. Use POST to start a run or GET to poll status."}
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 1. Extract & validate bearer token ──────────────────────────────────────
$authHeader = $Request.Headers['Authorization']
if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = '{"error":"Missing or invalid Authorization header. Expected: Bearer <token>"}'
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$rawToken = $authHeader.Substring(7).Trim()

# ─── 2. Parse request body ───────────────────────────────────────────────────
try {
    $body            = $Request.Body
    $suites          = if ($body.suites)            { @($body.suites) }            else { @('maester','cisa','eidsca','orca','cis') }
    $severities      = if ($body.severity)          { @($body.severity) }          else { @('Critical','High','Medium','Low','Info') }
    $extraTags       = if ($body.tags)              { @($body.tags) }              else { @() }
    $incLongRunning  = if ($null -ne $body.includeLongRunning) { [bool]$body.includeLongRunning } else { $false }
    $incPreview      = if ($null -ne $body.includePreview)     { [bool]$body.includePreview }     else { $false }
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = ([ordered]@{ error = "Failed to parse request body: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 3. Create job ID & persist initial state ────────────────────────────────
$jobId   = [guid]::NewGuid().ToString('N')   # 32-char hex, no dashes
$now     = [datetime]::UtcNow.ToString('o')
$jobFile = Join-Path $JOBS_DIR "$jobId.json"

Write-JobFile -Path $jobFile -Data ([ordered]@{
    jobId     = $jobId
    status    = 'running'
    createdAt = $now
    updatedAt = $now
    result    = $null
    error     = $null
})

# ─── 4. Cleanup old job files & finished thread jobs ─────────────────────────
try {
    $hardCutoff      = (Get-Date).AddHours(-$JOB_MAX_AGE_HOURS)
    $completedCutoff = (Get-Date).AddMinutes(-$JOB_COMPLETED_TIMEOUT_MINUTES)

    foreach ($jsonFile in (Get-ChildItem -Path $JOBS_DIR -Filter '*.json' -ErrorAction SilentlyContinue)) {
        # Hard upper bound — remove anything older than 2 hours regardless of state
        if ($jsonFile.LastWriteTimeUtc -lt $hardCutoff) {
            Remove-Item -Path $jsonFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        # Soft timeout — remove completed/failed files the frontend never fetched
        if ($jsonFile.LastWriteTimeUtc -lt $completedCutoff) {
            try {
                $d = Get-Content -Path $jsonFile.FullName -Raw | ConvertFrom-Json
                if ($d.status -in @('completed', 'failed')) {
                    Remove-Item -Path $jsonFile.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
} catch { }

try {
    Get-Job | Where-Object { $_.State -in @('Completed', 'Failed') } |
        Remove-Job -Force -ErrorAction SilentlyContinue
} catch { }

# ─── 5. Launch background thread job ─────────────────────────────────────────
# Start-ThreadJob creates a .NET thread within the same host process.
# On Azure Functions App Service Plan the process persists between invocations,
# so the thread continues running after this HTTP invocation returns.

$null = Start-ThreadJob -Name "maester-$jobId" -ArgumentList @(
    $rawToken,
    $suites,
    $severities,
    $extraTags,
    $incLongRunning,
    $incPreview,
    $jobFile,
    $jobId
) -ScriptBlock {
    param(
        [string]   $RawToken,
        [string[]] $Suites,
        [string[]] $Severities,
        [string[]] $ExtraTags,
        [bool]     $IncLongRunning,
        [bool]     $IncPreview,
        [string]   $JobFilePath,
        [string]   $JobId
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    $VerbosePreference     = 'SilentlyContinue'

    # ── Helper: update job file atomically ────────────────────────────────────
    function Update-Job {
        param([string]$Status, $Result, [string]$ErrorMsg)
        # Preserve createdAt from the original file
        $createdAt = [datetime]::UtcNow.ToString('o')
        if (Test-Path $JobFilePath) {
            try {
                $existing  = Get-Content -Path $JobFilePath -Raw | ConvertFrom-Json
                $createdAt = $existing.createdAt
            } catch { }
        }
        $data = [ordered]@{
            jobId     = $JobId
            status    = $Status
            createdAt = $createdAt
            updatedAt = [datetime]::UtcNow.ToString('o')
            result    = $Result
            error     = $ErrorMsg
        }
        $json    = $data | ConvertTo-Json -Depth 12 -Compress
        $tmpPath = "$JobFilePath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json)
        Move-Item -Path $tmpPath -Destination $JobFilePath -Force
    }

    $invocationTempDir = $null

    try {
        # ── Import modules ────────────────────────────────────────────────────
        # Thread runspaces start clean so explicit Import-Module is required.
        # Modules are pre-installed to /home/site/modules/ by profile.ps1 and
        # that path is registered in $env:PSModulePath, so these resolve from
        # disk instantly (no download, no managed-dependency delay).
        Import-Module -Name Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module -Name Pester -ErrorAction Stop
        Import-Module -Name Maester -ErrorAction Stop

        # ── Per-invocation temp directory ─────────────────────────────────────
        $invocationTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $invocationTempDir -Force

        # ── Connect to Microsoft Graph ────────────────────────────────────────
        $secureToken = ConvertTo-SecureString -String $RawToken -AsPlainText -Force
        Push-Location $invocationTempDir
        try {
            Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
        } finally {
            Pop-Location
        }

        # ── Resolve test paths ────────────────────────────────────────────────
        $allTestPaths = @()
        foreach ($suite in $Suites) {
            switch ($suite.ToLower()) {
                'maester' {
                    $mp = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                    if ($mp) { $allTestPaths += Join-Path $mp 'Tests' }
                }
                'eidsca' {
                    $mp = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                    if ($mp) { $allTestPaths += Join-Path $mp 'Tests' 'EIDSCA' }
                }
                'cis' {
                    $mp = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                    if ($mp) { $allTestPaths += Join-Path $mp 'Tests' 'CIS' }
                }
                'cisa' {
                    $mp = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                    if ($mp) { $allTestPaths += Join-Path $mp 'Tests' 'CISA' }
                }
                'orca' {
                    $mp = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                    if ($mp) { $allTestPaths += Join-Path $mp 'Tests' 'ORCA' }
                }
            }
        }

        $allTestPaths = @($allTestPaths | Select-Object -Unique | Where-Object { Test-Path $_ })
        if ($allTestPaths.Count -eq 0) {
            throw "No valid test paths resolved for suites: $($Suites -join ', '). Ensure the Maester module is installed."
        }

        # ── Build Pester tag filters ──────────────────────────────────────────
        $includeTags = @($Severities | ForEach-Object { "Severity:$_" }) + $ExtraTags
        $excludeTags = @()
        if (-not $IncLongRunning) { $excludeTags += 'LongRunning' }
        if (-not $IncPreview)     { $excludeTags += 'Preview' }

        # ── Configure Pester ──────────────────────────────────────────────────
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path         = $allTestPaths
        $pesterConfig.Run.PassThru     = $true
        $pesterConfig.Output.Verbosity = 'None'
        if ($includeTags.Count -gt 0) { $pesterConfig.Filter.Tag        = $includeTags }
        if ($excludeTags.Count -gt 0) { $pesterConfig.Filter.ExcludeTag = $excludeTags }

        # ── Run Maester ───────────────────────────────────────────────────────
        $runStart = [datetime]::UtcNow
        Invoke-Maester `
            -PesterConfiguration $pesterConfig `
            -OutputFolder        $invocationTempDir `
            -OutputJsonFileName  'results.json' `
            -NonInteractive `
            -SkipGraphConnect `
            -ErrorAction Stop
        $runEnd = [datetime]::UtcNow

        # ── Disconnect Graph ──────────────────────────────────────────────────
        Disconnect-MgGraph -ErrorAction SilentlyContinue

        # ── Read Maester JSON output ──────────────────────────────────────────
        $jsonPath = Join-Path $invocationTempDir 'results.json'
        if (-not (Test-Path $jsonPath)) {
            throw 'Maester did not produce a results file. Ensure the Maester module is installed and tests ran successfully.'
        }
        $maesterJson = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

        # ── Transform to PipePal response format ─────────────────────────────
        $flatTests = @()
        foreach ($test in $maesterJson.Tests) {
            $severity = 'Info'
            if ($test.Severity) {
                $severity = $test.Severity
            } elseif ($test.Tag) {
                $sevTag = $test.Tag | Where-Object { $_ -like 'Severity:*' } | Select-Object -First 1
                if ($sevTag) { $severity = $sevTag -replace '^Severity:', '' }
            }

            $testId = $test.Tag | Where-Object { $_ -match '^[A-Z]+(\.[A-Z0-9]+)+$' } | Select-Object -First 1
            if (-not $testId) { $testId = $test.Name -replace '\s+', '-' }

            $flatTests += [ordered]@{
                id          = $testId
                name        = $test.Name
                result      = $test.Result
                duration    = if ($test.Duration) { [math]::Round([double]$test.Duration) } else { 0 }
                severity    = $severity
                category    = if ($test.Block) { ($test.Block -split '[.\s]' | Select-Object -First 1).Trim() } else { '' }
                block       = if ($test.Block) { $test.Block } else { '' }
                errorRecord = if ($test.ErrorRecord) { [string]$test.ErrorRecord } else { $null }
            }
        }

        $summary = [ordered]@{
            totalCount     = if ($maesterJson.TotalCount)             { $maesterJson.TotalCount }   else { $flatTests.Count }
            passedCount    = if ($maesterJson.PassedCount)            { $maesterJson.PassedCount }  else { ($flatTests | Where-Object { $_.result -eq 'Passed'  }).Count }
            failedCount    = if ($maesterJson.FailedCount)            { $maesterJson.FailedCount }  else { ($flatTests | Where-Object { $_.result -eq 'Failed'  }).Count }
            skippedCount   = if ($maesterJson.SkippedCount -ne $null) { $maesterJson.SkippedCount + ($maesterJson.NotRunCount ?? 0) } else { ($flatTests | Where-Object { $_.result -in @('Skipped','NotRun') }).Count }
            durationMs     = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
            timestamp      = if ($maesterJson.ExecutedAt) { $maesterJson.ExecutedAt } else { $runStart.ToString('o') }
            suitesRun      = $Suites
            severityFilter = $Severities
            tests          = $flatTests
        }

        # ── Write completed result ────────────────────────────────────────────
        Update-Job -Status 'completed' -Result $summary -ErrorMsg $null

    } catch {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Update-Job -Status 'failed' -Result $null -ErrorMsg $_.Exception.Message
    } finally {
        if ($invocationTempDir -and (Test-Path $invocationTempDir)) {
            Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── 6. Return jobId immediately (HTTP 202 Accepted) ─────────────────────────
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::Accepted
    Body       = ([ordered]@{
        jobId     = $jobId
        status    = 'running'
        createdAt = $now
    } | ConvertTo-Json -Compress)
    Headers    = @{ 'Content-Type' = 'application/json' }
})
