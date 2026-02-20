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
        Body       = "{`"error`":`"Failed to parse request body: $($_.Exception.Message)`"}"
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 3. Connect to Microsoft Graph ───────────────────────────────────────────
try {
    Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = "{`"error`":`"Failed to connect to Microsoft Graph: $($_.Exception.Message)`"}"
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
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests\EIDSCA' }
            }
            'cis' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests\CIS' }
            }
            'cisa' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests\CISA' }
            }
            'orca' {
                $modulePath = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
                if ($modulePath) { $allTestPaths += Join-Path $modulePath 'Tests\ORCA' }
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
        Body       = "{`"error`":`"Failed to resolve test paths: $($_.Exception.Message)`"}"
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
try {
    $runStart = [datetime]::UtcNow
    $results  = Invoke-Maester `
        -PesterConfiguration $pesterConfig `
        -NonInteractive `
        -PassThru `
        -SkipGraphConnect `
        # -NoLogo `
        -ErrorAction Stop
    $runEnd = [datetime]::UtcNow
} catch {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "{`"error`":`"Maester run failed: $($_.Exception.Message)`"}"
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# ─── 8. Disconnect from Graph ────────────────────────────────────────────────
Disconnect-MgGraph -ErrorAction SilentlyContinue

# ─── 9. Flatten test results ─────────────────────────────────────────────────
$flatTests = @()
if ($results -and $results.Tests) {
    foreach ($test in $results.Tests) {
        # Extract severity from Tags (format: "Severity:High")
        $severity = 'Info'
        if ($test.Tag) {
            $sevTag = $test.Tag | Where-Object { $_ -like 'Severity:*' } | Select-Object -First 1
            if ($sevTag) { $severity = $sevTag -replace '^Severity:', '' }
        }

        # Extract category from block hierarchy (first segment of block names)
        $category = ''
        if ($test.Block) {
            $category = ($test.Block.Name -split '\.' | Select-Object -First 1)
        }

        $errorMsg = $null
        if ($test.Result -eq 'Failed' -and $test.ErrorRecord) {
            $errorMsg = $test.ErrorRecord.Exception.Message
        }

        $flatTests += [ordered]@{
            id          = $test.Name -replace '\s+', '-'
            name        = $test.Name
            result      = $test.Result           # 'Passed','Failed','Skipped','NotRun'
            duration    = [math]::Round($test.Duration.TotalMilliseconds)
            severity    = $severity
            category    = $category
            block       = if ($test.Block) { $test.Block.Name } else { '' }
            errorRecord = $errorMsg
        }
    }
}

# ─── 10. Build response summary ──────────────────────────────────────────────
$passedCount  = ($flatTests | Where-Object { $_.result -eq 'Passed'  }).Count
$failedCount  = ($flatTests | Where-Object { $_.result -eq 'Failed'  }).Count
$skippedCount = ($flatTests | Where-Object { $_.result -in @('Skipped','NotRun') }).Count

$summary = [ordered]@{
    totalCount    = $flatTests.Count
    passedCount   = $passedCount
    failedCount   = $failedCount
    skippedCount  = $skippedCount
    durationMs    = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
    timestamp     = $runStart.ToString('o')   # ISO 8601
    suitesRun     = $suites
    severityFilter = $severities
    tests         = $flatTests
}

$responseBody = $summary | ConvertTo-Json -Depth 10 -Compress

# ─── 11. Return response ─────────────────────────────────────────────────────
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $responseBody
    Headers    = @{ 'Content-Type' = 'application/json' }
})
