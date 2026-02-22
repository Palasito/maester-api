# lib/result-transformer.ps1 — Maester JSON → PipePal format transformer
#
# Converts the raw Maester/Pester output (results.json) into the flat
# structure that PipePal's frontend expects.  Extracted from the thread
# job scriptblock so it can be unit-tested and reused.

function ConvertTo-PipePalResult {
    <#
    .SYNOPSIS  Transform Maester results.json into the PipePal API contract.
    .PARAMETER MaesterJson
        Parsed results.json object (from ConvertFrom-Json).
    .PARAMETER Suites
        Array of suite names the user originally requested.
    .PARAMETER Severities
        Array of severity filters the user originally requested.
    .PARAMETER RunStart
        [datetime] UTC when the test run began.
    .PARAMETER RunEnd
        [datetime] UTC when the test run finished.
    .OUTPUTS
        [ordered] hashtable matching the PipePal result contract:
        { totalCount, passedCount, failedCount, skippedCount, durationMs,
          timestamp, suitesRun, severityFilter, tests: [ ... ] }
    #>
    param(
        [Parameter(Mandatory)] $MaesterJson,
        [Parameter(Mandatory)][string[]] $Suites,
        [string[]] $Severities,
        [Parameter(Mandatory)][datetime] $RunStart,
        [Parameter(Mandatory)][datetime] $RunEnd
    )

    # ── Flatten individual test results ───────────────────────────────────────
    $flatTests = @()
    foreach ($test in $MaesterJson.Tests) {

        # Resolve severity — prefer explicit property, fall back to tag
        $severity = 'Info'
        if ($test.Severity) {
            $severity = $test.Severity
        }
        elseif ($test.Tag) {
            $sevTag = $test.Tag |
                Where-Object { $_ -like 'Severity:*' } |
                Select-Object -First 1
            if ($sevTag) { $severity = $sevTag -replace '^Severity:', '' }
        }

        # Resolve test ID — prefer structured tag, fall back to sanitised name
        $testId = $test.Tag |
            Where-Object { $_ -match '^[A-Z]+(\.[A-Z0-9]+)+$' } |
            Select-Object -First 1
        if (-not $testId) { $testId = $test.Name -replace '\s+', '-' }

        $flatTests += [ordered]@{
            id          = $testId
            name        = $test.Name
            result      = $test.Result
            duration    = if ($test.Duration) {
                              try   { [math]::Round([timespan]::Parse($test.Duration).TotalMilliseconds) }
                              catch { try { [math]::Round([double]$test.Duration) } catch { 0 } }
                          } else { 0 }
            severity    = $severity
            category    = if ($test.Block) { ($test.Block -split '[.\s]' | Select-Object -First 1).Trim() } else { '' }
            block       = if ($test.Block) { $test.Block } else { '' }
            errorRecord = if ($test.ErrorRecord) { [string]$test.ErrorRecord } else { $null }
        }
    }

    # ── Build summary ─────────────────────────────────────────────────────────
    $summary = [ordered]@{
        totalCount     = if ($MaesterJson.TotalCount)             { $MaesterJson.TotalCount }
                         else { $flatTests.Count }
        passedCount    = if ($MaesterJson.PassedCount)            { $MaesterJson.PassedCount }
                         else { ($flatTests | Where-Object { $_.result -eq 'Passed'  }).Count }
        failedCount    = if ($MaesterJson.FailedCount)            { $MaesterJson.FailedCount }
                         else { ($flatTests | Where-Object { $_.result -eq 'Failed'  }).Count }
        skippedCount   = if ($MaesterJson.SkippedCount -ne $null) {
                            $MaesterJson.SkippedCount + ($MaesterJson.NotRunCount ?? 0)
                         } else {
                            ($flatTests | Where-Object { $_.result -in @('Skipped','NotRun') }).Count
                         }
        durationMs     = [math]::Round(($RunEnd - $RunStart).TotalMilliseconds)
        timestamp      = if ($MaesterJson.ExecutedAt) { $MaesterJson.ExecutedAt }
                         else { $RunStart.ToString('o') }
        suitesRun      = $Suites
        severityFilter = if ($Severities) { $Severities } else { @() }
        tests          = $flatTests
    }

    return $summary
}
