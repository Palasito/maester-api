# MaesterRunner Azure Function (PowerShell)
# Triggered via HTTP POST from PipePal proxy-maester.ts
#
# Expected request body (JSON):
#   {
#     "suites":            string[]   // e.g. ["maester","cisa","eidsca","orca","cis"]
#     "severity":          string[]   // e.g. ["Critical","High","Medium"]
#     "tags":              string[]   // optional extra Pester tags
#     "includeLongRunning": bool      // default false — exclude tests tagged LongRunning
#     "includePreview":    bool       // default false — exclude tests tagged Preview
#   }
#
# The caller must pass a valid Microsoft Graph delegated token in the
# Authorization header:  Authorization: Bearer <token>
# The token must be acquired with the Maester-required scopes.

using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

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

$rawToken   = $authHeader.Substring(7).Trim()
$secureToken = ConvertTo-SecureString -String $rawToken -AsPlainText -Force

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

# ─── 3. Connect to Microsoft Graph ───────────────────────────────────────────
try {
    # Connect-MgGraph writes a context file to .mg/mg.context.json relative to
    # the current working directory. To prevent file-lock collisions when multiple
    # invocations run concurrently on the same instance, each invocation switches
    # to its own unique temp directory before connecting, then restores cwd after.
    $invocationTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    $null = New-Item -ItemType Directory -Path $invocationTempDir -Force
    Push-Location $invocationTempDir
    try {
        Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    } finally {
        Pop-Location
    }
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = ([ordered]@{ error = "Failed to connect to Microsoft Graph: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 4. Resolve test paths from suite names ──────────────────────────────────
# Maester tests are installed by the Maester module via Install-MaesterTests.
# When the module is loaded, tests reside in the module's own directory.
# We use Get-MaesterTests to enumerate paths rather than hardcoding them.

try {
    # Ask Maester where its bundled tests live for each requested suite
    $allTestPaths = @()

    foreach ($suite in $suites) {
        switch ($suite.ToLower()) {
            'maester' {
                # Core Maester tests (MT.*)
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests' }
            }
            'eidsca' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests' 'EIDSCA' }
            }
            'cis' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests' 'CIS' }
            }
            'cisa' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests' 'CISA' }
            }
            'orca' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests' 'ORCA' }
            }
        }
    }

    # Deduplicate and validate paths exist
    $allTestPaths = @($allTestPaths | Select-Object -Unique | Where-Object { Test-Path $_ })

    if ($allTestPaths.Count -eq 0) {
        throw "No valid test paths resolved for suites: $($suites -join ', '). Ensure the Maester module is installed."
    }
} catch {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = ([ordered]@{ error = "Failed to resolve test paths: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 5. Build Pester tag filters ─────────────────────────────────────────────
# Maester tags tests with their severity (e.g. "Severity:High").
# We include only the requested severities via Tag.Include.
# We also exclude LongRunning / Preview unless the caller opts in.

$includeTags = @($severities | ForEach-Object { "Severity:$_" }) + $extraTags
$excludeTags = @()
if (-not $incLongRunning) { $excludeTags += 'LongRunning' }
if (-not $incPreview)     { $excludeTags += 'Preview' }

# ─── 6. Configure Pester ─────────────────────────────────────────────────────
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path        = $allTestPaths
$pesterConfig.Run.PassThru    = $true
$pesterConfig.Output.Verbosity = 'None'

if ($includeTags.Count -gt 0) {
    $pesterConfig.Filter.Tag = $includeTags
}
if ($excludeTags.Count -gt 0) {
    $pesterConfig.Filter.ExcludeTag = $excludeTags
}

# ─── 7. Run Maester ──────────────────────────────────────────────────────────
# We do NOT use -PassThru. Instead we rely on the JSON file Maester writes to
# $invocationTempDir/results.json as the authoritative source of results.
# This avoids depending on the in-memory Pester result object, which can be
# $null or incomplete depending on Maester version and how tests exit.
try {
    $runStart = [datetime]::UtcNow
    Invoke-Maester `
        -PesterConfiguration $pesterConfig `
        -OutputFolder        $invocationTempDir `
        -OutputJsonFileName  'results.json' `
        -NonInteractive `
        -SkipGraphConnect `
        -ErrorAction Stop
    $runEnd = [datetime]::UtcNow
} catch {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = ([ordered]@{ error = "Maester run failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 8. Disconnect from Graph ────────────────────────────────────────────────
Disconnect-MgGraph -ErrorAction SilentlyContinue

# ─── 9. Read Maester JSON output file ────────────────────────────────────────
$jsonPath = Join-Path $invocationTempDir 'results.json'
if (-not (Test-Path $jsonPath)) {
    Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = ([ordered]@{ error = "Maester did not produce a results file. Ensure the Maester module is installed and tests ran successfully." } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

try {
    $maesterJson = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
} catch {
    Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = ([ordered]@{ error = "Failed to parse Maester results file: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 10. Transform to PipePal response format ────────────────────────────────
$flatTests = @()
foreach ($test in $maesterJson.Tests) {
    # Severity — Maester may expose it as a direct property or inside the Tag array
    $severity = 'Info'
    if ($test.Severity) {
        $severity = $test.Severity
    } elseif ($test.Tag) {
        $sevTag = $test.Tag | Where-Object { $_ -like 'Severity:*' } | Select-Object -First 1
        if ($sevTag) { $severity = $sevTag -replace '^Severity:', '' }
    }

    # ID — prefer a tag that looks like a test ID (e.g. "EIDSCA.AP01", "MT.1001")
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
    totalCount     = if ($maesterJson.TotalCount)   { $maesterJson.TotalCount }   else { $flatTests.Count }
    passedCount    = if ($maesterJson.PassedCount)  { $maesterJson.PassedCount }  else { ($flatTests | Where-Object { $_.result -eq 'Passed'  }).Count }
    failedCount    = if ($maesterJson.FailedCount)  { $maesterJson.FailedCount }  else { ($flatTests | Where-Object { $_.result -eq 'Failed'  }).Count }
    skippedCount   = if ($maesterJson.SkippedCount -ne $null) { $maesterJson.SkippedCount + ($maesterJson.NotRunCount ?? 0) } else { ($flatTests | Where-Object { $_.result -in @('Skipped','NotRun') }).Count }
    durationMs     = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
    timestamp      = if ($maesterJson.ExecutedAt)   { $maesterJson.ExecutedAt }   else { $runStart.ToString('o') }
    suitesRun      = $suites
    severityFilter = $severities
    tests          = $flatTests
}

$responseBody = $summary | ConvertTo-Json -Depth 10 -Compress

# ─── 11. Clean up per-invocation temp directory ──────────────────────────────
Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue

# ─── 12. Return response ─────────────────────────────────────────────────────
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $responseBody
    Headers    = @{ 'Content-Type' = 'application/json' }
})
