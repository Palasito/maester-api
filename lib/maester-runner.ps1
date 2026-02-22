# lib/maester-runner.ps1 — Child-process job scriptblock for Maester test execution
#
# This file defines the $MaesterRunnerScriptBlock that server.ps1 passes
# to Start-Job.  The scriptblock is self-contained: it re-imports all modules
# (child processes start clean) and writes results to SQLite.
#
# Using Start-Job (child process) rather than Start-ThreadJob means the ~300 MB
# of Maester/Pester/Graph module assemblies are fully reclaimed by the OS when
# the child process exits — keeping the long-running Pode server process lean.
#
# Phase 1: Graph-only authentication.
# Phase 3: adds Exchange Online + Microsoft Teams (optional headers).

$MaesterRunnerScriptBlock = {
    param(
        [string]   $GraphToken,
        [string[]] $Suites,
        [string[]] $Severities,
        [string[]] $ExtraTags,
        [bool]     $IncLongRunning,
        [bool]     $IncPreview,
        [string]   $JobId,
        [string]   $DbPath,
        # Phase 3 — optional tokens for Exchange Online & Teams tests
        [string]   $ExchangeToken,         # Access token for https://outlook.office365.com (delegated)
        [string]   $TeamsToken,             # Access token for Teams resource (delegated)
        [string]   $TenantId,              # Customer tenant ID (required for Exchange connection)
        [string]   $TestsPath,             # Path to Install-MaesterTests output (fallback: module built-in)
        # App-credentials path (client_credentials flow) — preferred over delegated tokens
        [string]   $MaesterClientId,       # App registration client ID in customer tenant
        [string]   $MaesterClientSecret    # Client secret (session-only, never persisted)
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    $VerbosePreference     = 'SilentlyContinue'

    # ── Local helper: update job in SQLite ────────────────────────────────────
    # We inline a minimal update function so the scriptblock stays self-contained
    # (thread jobs cannot call functions from the parent scope).
    function Update-Job {
        param(
            [string] $Status,
            [string] $Result,
            [string] $ErrorMsg,
            [int]    $DurationMs = 0
        )
        $now = [datetime]::UtcNow.ToString('o')
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
            UPDATE jobs
            SET    status      = @status,
                   updated_at  = @now,
                   result      = @result,
                   error       = @errorMsg,
                   duration_ms = @durationMs
            WHERE  job_id      = @jobId
"@ -SqlParameters @{
            jobId      = $JobId
            status     = $Status
            now        = $now
            result     = $Result
            errorMsg   = $ErrorMsg
            durationMs = $DurationMs
        }
    }

    $invocationTempDir = $null

    try {
        # ── 1. Import modules (thread runspaces start empty) ──────────────────
        Import-Module -Name PSSQLite                       -ErrorAction Stop
        Import-Module -Name Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module -Name Pester                         -ErrorAction Stop
        Import-Module -Name Maester                        -ErrorAction Stop

        # Phase 3 modules — import conditionally
        $needsExchange = $ExchangeToken -or ($MaesterClientId -and $MaesterClientSecret -and $TenantId)
        $needsTeams    = $TeamsToken    -or ($MaesterClientId -and $MaesterClientSecret -and $TenantId)
        if ($needsExchange) {
            Import-Module -Name ExchangeOnlineManagement   -ErrorAction Stop
        }
        if ($needsTeams) {
            Import-Module -Name MicrosoftTeams             -ErrorAction Stop
        }

        # ── 2. Create isolated temp directory for this run ────────────────────
        $invocationTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $invocationTempDir -Force

        # ── 3. Connect to Microsoft Graph (REQUIRED) ─────────────────────────
        # Path A — app-credential path: acquire a new Graph token via
        # client_credentials so *all* tests run under the app registration's
        # application permissions instead of the delegated (user) token.
        # Path B — delegated path: use the $GraphToken forwarded by the caller.
        $graphTokenToUse = $GraphToken
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            try {
                $graphCcBody = @{
                    grant_type    = 'client_credentials'
                    client_id     = $MaesterClientId
                    client_secret = $MaesterClientSecret
                    scope         = 'https://graph.microsoft.com/.default'
                }
                $graphCcResp = Invoke-RestMethod `
                    -Uri         "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                    -Method      Post `
                    -Body        $graphCcBody `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -ErrorAction Stop
                $graphTokenToUse = $graphCcResp.access_token
                Write-Host '[maester-runner] Graph token acquired via client_credentials (app reg path).'
            }
            catch {
                # On the app-reg path there is no delegated GraphToken to fall back to.
                # Re-throw immediately instead of attempting ConvertTo-SecureString on ''.
                if (-not $GraphToken) {
                    throw "client_credentials Graph token acquisition failed (no delegated fallback available): $($_.Exception.Message)"
                }
                Write-Warning "[maester-runner] client_credentials Graph token failed: $($_.Exception.Message). Falling back to delegated token."
                $graphTokenToUse = $GraphToken
            }
        }

        # Guard against an empty token (e.g. TenantId was not forwarded by the caller).
        if (-not $graphTokenToUse) {
            throw "No Graph token available. Ensure tenantId is included in the request body when using the app-reg path, or provide an Authorization: Bearer token on the delegated path."
        }

        $secureToken = ConvertTo-SecureString -String $graphTokenToUse -AsPlainText -Force
        Push-Location $invocationTempDir
        try {
            Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
        }
        finally {
            Pop-Location
        }

        # ── 3a. Connect to Exchange Online (Phase 3 — OPTIONAL) ──────────────
        # Two paths:
        #   A) App-credential path: acquire token via client_credentials flow
        #      (no delegated Exchange token needed — uses Exchange.ManageAsApp).
        #   B) Delegated path: caller pre-acquired an ExchangeToken.
        $exchangeConnected = $false
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            # Path A — client_credentials
            try {
                $tokenBody = @{
                    grant_type    = 'client_credentials'
                    client_id     = $MaesterClientId
                    client_secret = $MaesterClientSecret
                    scope         = 'https://outlook.office365.com/.default'
                }
                $tokenResp = Invoke-RestMethod `
                    -Uri    "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                    -Method Post `
                    -Body   $tokenBody `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -ErrorAction Stop

                $exoToken = ConvertTo-SecureString $tokenResp.access_token -AsPlainText -Force
                Connect-ExchangeOnline `
                    -AccessToken  $exoToken `
                    -Organization $TenantId `
                    -ShowBanner:$false `
                    -ErrorAction Stop
                $exchangeConnected = $true
                Write-Host '[maester-runner] Exchange Online connected via client_credentials.'
            }
            catch {
                # Exchange Online connection via client_credentials requires TWO things in the customer tenant:
                #   1. API permission: Exchange Online > Application > Exchange.ManageAsApp
                #      (granted via Entra admin centre > API permissions, NOT Graph)
                #   2. Exchange Online RBAC role: 'View-Only Configuration' assigned to the
                #      app's service principal in Exchange Admin Centre > Roles > Admin roles.
                # Without both, Connect-ExchangeOnline will fail and ORCA tests will skip.
                Write-Warning "Exchange Online (app-credentials) connection failed: $($_.Exception.Message). Ensure the service principal has Exchange.ManageAsApp permission AND the 'View-Only Configuration' Exchange RBAC role assigned."
            }
        } elseif ($ExchangeToken -and $TenantId) {
            # Path B — delegated token (legacy)
            try {
                Connect-ExchangeOnline `
                    -AccessToken      $ExchangeToken `
                    -Organization     $TenantId `
                    -ShowBanner:$false `
                    -ErrorAction Stop
                $exchangeConnected = $true
            }
            catch {
                Write-Warning "Exchange Online connection failed: $($_.Exception.Message)"
            }
        }

        # ── 3b. Connect to Microsoft Teams (Phase 3 — OPTIONAL) ──────────────
        # Two paths:
        #   A) App-credential path: Connect-MicrosoftTeams with client secret.
        #   B) Delegated path: AccessTokens array (Graph + Teams tokens).
        $teamsConnected = $false
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            # Path A — client_credentials via Connect-MicrosoftTeams
            try {
                $secureSecret = ConvertTo-SecureString $MaesterClientSecret -AsPlainText -Force
                Connect-MicrosoftTeams `
                    -TenantId    $TenantId `
                    -ClientId    $MaesterClientId `
                    -ClientSecret $secureSecret `
                    -ErrorAction Stop
                $teamsConnected = $true
                Write-Host '[maester-runner] Microsoft Teams connected via client_credentials.'
            }
            catch {
                Write-Warning "Microsoft Teams (app-credentials) connection failed: $($_.Exception.Message)"
            }
        } elseif ($TeamsToken -and $GraphToken) {
            # Path B — delegated tokens (legacy)
            try {
                $tokens = @($GraphToken, $TeamsToken)
                Connect-MicrosoftTeams -AccessTokens $tokens -ErrorAction Stop
                $teamsConnected = $true
            }
            catch {
                Write-Warning "Microsoft Teams connection failed: $($_.Exception.Message)"
            }
        }

        # ── 4. Resolve the effective test path ───────────────────────────────
        #
        # Strategy (answers: "use the root when running all"):
        #
        #   • 0 or ALL installed suites selected  → pass $testRoot directly.
        #     Invoke-Maester recurses every subdirectory, which is exactly the
        #     "run all" behaviour and avoids any path-array coercion issues.
        #
        #   • Exactly ONE suite selected           → pass the single
        #     subdirectory path as a string scalar.
        #
        #   • Multiple but NOT all suites selected → still pass $testRoot but
        #     rely on the caller's Pester tag/suite filters to limit scope.
        #     Pester's StringArrayOption coerces an array to a space-joined
        #     string (a known Pester quirk), so a single root path is safer.
        #
        # Priority for $testRoot: $TestsPath (Install-MaesterTests) → module.

        $testRoot = $null
        if ($TestsPath -and (Test-Path $TestsPath)) {
            $testRoot = $TestsPath
        }
        if (-not $testRoot) {
            $maesterBase = (Get-Module -Name Maester -ListAvailable | Select-Object -First 1).ModuleBase
            if ($maesterBase) { $testRoot = Join-Path $maesterBase 'maester-tests' }
        }
        if (-not $testRoot -or -not (Test-Path $testRoot)) {
            throw "No Maester test directory found. Ensure Install-MaesterTests ran during container startup."
        }

        # Known suite → subdirectory mapping
        $suiteMap = @{
            maester = 'Maester'
            eidsca  = 'EIDSCA'
            cis     = 'cis'
            cisa    = 'cisa'
            orca    = 'orca'
            xspm    = 'XSPM'
        }

        # Installed suites = subdirectories that actually exist under $testRoot
        $installedSuites = @($suiteMap.Keys | Where-Object {
            Test-Path (Join-Path $testRoot $suiteMap[$_])
        })

        # Requested suites normalised to lower-case
        $requestedSuites = @($Suites | ForEach-Object { $_.ToLower() } | Where-Object { $suiteMap.ContainsKey($_) })

        # Decide the effective path to hand to Pester
        $selectedCount  = $requestedSuites.Count
        $installedCount = $installedSuites.Count

        # Decide the effective path to hand to Pester.
        # IMPORTANT: Pester v5 StringArrayOption space-joins arrays when assigned via =,
        # producing an invalid single-path string. Always pass a scalar string.
        # For a single suite use the specific subdirectory; otherwise use $testRoot and
        # let Maester recurse — suite filtering happens via Maester's own suite logic.
        $effectivePath = if ($requestedSuites.Count -eq 1) {
            $sub = Join-Path $testRoot $suiteMap[$requestedSuites[0]]
            if (Test-Path $sub) { $sub } else { $testRoot }
        } else {
            # Zero (= all) or multiple suites: always pass the root as a single string
            $testRoot
        }

        # ── 5. Build Pester tag filters ───────────────────────────────────────
        # IMPORTANT: Do NOT add Severity:* to Filter.Tag.
        # Maester stores severity in its own JSON metadata, NOT as Pester tags.
        # Applying a Severity:* tag filter here causes Pester to mark every
        # test that lacks the tag as NOTRUN (skipped), regardless of severity.
        # Severity filtering is applied in post-processing (step 9b below).
        #
        # IMPORTANT: Do NOT add LongRunning/Preview to ExcludeTag here.
        # Invoke-Maester 2.x manages those exclusions internally based on
        # its own -IncludeLongRunning and -IncludePreview switch parameters.
        # If we also add them to Pester's ExcludeTag, they get added TWICE
        # (once by us here, once inside Invoke-Maester's GetPesterConfiguration)
        # which works but is redundant. More importantly, when we WANT to include
        # them, Invoke-Maester re-adds the exclusion unless we pass the switches.
        # The correct pattern is: pass $IncLongRunning/$IncPreview as switches
        # directly to Invoke-Maester, and keep ExcludeTag clean for caller tags.
        $includeTags = @($ExtraTags | Where-Object { $_ })   # extra caller tags only
        $excludeTags = @()                                    # no manual LongRunning/Preview here

        # ── 6. Configure Pester ───────────────────────────────────────────────
        $pesterConfig = New-PesterConfiguration
        # Always assign a scalar string — see path selection comment above.
        $pesterConfig.Run.Path         = $effectivePath
        $pesterConfig.Run.PassThru     = $true
        $pesterConfig.Output.Verbosity = 'None'
        if ($includeTags.Count -gt 0) { $pesterConfig.Filter.Tag = $includeTags }
        # ExcludeTag for LongRunning/Preview is handled by Invoke-Maester's own
        # -IncludeLongRunning and -IncludePreview switch parameters (see step 7).
        # Do NOT set ExcludeTag here for those two — passing the switches below
        # is the correct and only required mechanism.

        # ── 7. Run Maester ────────────────────────────────────────────────────
        $runStart = [datetime]::UtcNow
        $jsonPath = Join-Path $invocationTempDir 'results.json'

        # NOTE: Do NOT pass -OutputFolder alongside -OutputJsonFile.
        # Invoke-Maester's ValidateAndSetOutputFiles overrides OutputJsonFile
        # with a timestamped filename whenever OutputFolder is non-empty.
        Invoke-Maester `
            -PesterConfiguration  $pesterConfig `
            -OutputJsonFile       $jsonPath `
            -NonInteractive `
            -SkipGraphConnect `
            -IncludeLongRunning:$IncLongRunning `
            -IncludePreview:$IncPreview `
            -ErrorAction Stop

        $runEnd = [datetime]::UtcNow

        # Disconnect all services immediately after tests
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        if ($exchangeConnected) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        }
        if ($teamsConnected) {
            Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue
        }

        # ── 8. Read results file ──────────────────────────────────────────────
        if (-not (Test-Path $jsonPath)) {
            throw 'Maester did not produce a results file.'
        }
        $maesterJson = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

        # ── 9. Transform to PipePal format ────────────────────────────────────
        # Inline transformation (same logic as lib/result-transformer.ps1,
        # duplicated here because thread scriptblocks can't dot-source files).
        $flatTests = @()
        foreach ($test in $maesterJson.Tests) {
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

        # ── 9b. Severity filter (post-run) ────────────────────────────────────
        # Apply severity filtering here rather than via Pester tags (see step 5).
        if ($Severities -and $Severities.Count -gt 0) {
            $allKnownSeverities = @('Critical', 'High', 'Medium', 'Low', 'Info')
            $isAllSeverities    = $Severities.Count -ge $allKnownSeverities.Count
            if (-not $isAllSeverities) {
                $flatTests = @($flatTests | Where-Object { $_.severity -in $Severities })
            }
        }

        $summary = [ordered]@{
            # Always compute counts from $flatTests so they reflect any
            # post-run severity filtering applied above.
            totalCount     = $flatTests.Count
            passedCount    = ($flatTests | Where-Object { $_.result -eq 'Passed'  }).Count
            failedCount    = ($flatTests | Where-Object { $_.result -eq 'Failed'  }).Count
            skippedCount   = ($flatTests | Where-Object { $_.result -in @('Skipped','NotRun') }).Count
            durationMs     = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
            timestamp      = if ($maesterJson.ExecutedAt) { $maesterJson.ExecutedAt }
                             else { $runStart.ToString('o') }
            suitesRun      = $Suites
            severityFilter = $Severities
            tests          = $flatTests
        }

        # ── 10. Write result to SQLite ────────────────────────────────────────
        $resultJson = $summary | ConvertTo-Json -Depth 12 -Compress
        $durationMs = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
        Update-Job -Status 'completed' -Result $resultJson -ErrorMsg $null -DurationMs $durationMs

    }
    catch {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue
        $errMsg = $_.Exception.Message
        try { Update-Job -Status 'failed' -Result $null -ErrorMsg $errMsg -DurationMs 0 } catch { }
    }
    finally {
        # ── 11. Cleanup temp directory ────────────────────────────────────────
        if ($invocationTempDir -and (Test-Path $invocationTempDir)) {
            Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
