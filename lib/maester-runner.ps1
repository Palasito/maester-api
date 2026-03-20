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
# Auth model: app-registration only (client_credentials grant).
# The runner acquires all service tokens itself using the supplied client ID +
# secret.  No delegated / device-code tokens are forwarded by the caller.
# Services covered: Microsoft Graph, Exchange Online, Security & Compliance
# (IPPS), Microsoft Teams, and Azure (Az.Accounts).

$MaesterRunnerScriptBlock = {
    param(
        [string]   $GraphToken,            # MSAL workspace Graph token (proxy-route auth + Connect-MgGraph)
        [string[]] $Suites,
        [string[]] $Severities,
        [string[]] $ExtraTags,
        [bool]     $IncLongRunning,
        [bool]     $IncPreview,
        [string]   $JobId,
        [string]   $DbPath,
        [string]   $TenantId,              # Customer tenant ID (required for all service connections)
        [string]   $TestsPath,             # Path to Install-MaesterTests output (fallback: module built-in)
        # App-registration credentials — runner acquires all service tokens itself
        [string]   $MaesterClientId,       # Application (client) ID of the Maester app registration
        [string]   $MaesterClientSecret    # Client secret value
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    $VerbosePreference     = 'SilentlyContinue'

    # ── Local helpers ─────────────────────────────────────────────────────────
    # Inlined so the scriptblock stays self-contained (child processes cannot
    # call functions from the parent scope).

    # Acquire an app-only access token via the OAuth 2.0 client_credentials grant.
    # SECURITY: This function handles secrets — never log the client_secret or resulting tokens.
    function Get-ClientCredentialToken {
        param(
            [string] $TenantId,
            [string] $ClientId,
            [string] $ClientSecret,
            [string] $Scope
        )
        $body = @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $Scope
        }
        $resp = Invoke-RestMethod `
            -Uri         "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method      POST `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body        $body `
            -ErrorAction Stop
        return $resp.access_token
    }

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

        # App-reg service modules — import conditionally based on credentials being present
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            Import-Module -Name ExchangeOnlineManagement   -ErrorAction Stop
            Import-Module -Name MicrosoftTeams             -ErrorAction Stop
            Import-Module -Name Az.Accounts                -ErrorAction Stop
        }

        # ── 2. Create isolated temp directory for this run ────────────────────
        $invocationTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $invocationTempDir -Force

        # ── 3. Connect to Microsoft Graph (REQUIRED) ─────────────────────────
        # When app-registration credentials are available, ALWAYS use them to
        # acquire a Graph token via client_credentials.  This token carries the
        # full application permission set granted to the app-reg — it does not
        # depend on delegated consent from the user.
        #
        # The MSAL workspace token ($GraphToken) forwarded by PipePal is used
        # only for proxy-route auth and may carry only BASE scopes; it is NOT
        # sufficient for the broad Graph queries Maester runs.
        $graphTokenToUse = $null
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            Write-Host '[maester-runner] Acquiring Graph token via client_credentials (app-registration).'
            $graphTokenToUse = Get-ClientCredentialToken `
                -TenantId     $TenantId `
                -ClientId     $MaesterClientId `
                -ClientSecret $MaesterClientSecret `
                -Scope        'https://graph.microsoft.com/.default'
        }
        # Fallback: use the delegated MSAL token if no app creds were supplied.
        if (-not $graphTokenToUse -and $GraphToken) {
            Write-Host '[maester-runner] No app credentials — using delegated MSAL Graph token.'
            $graphTokenToUse = $GraphToken
        }

        if (-not $graphTokenToUse) {
            throw 'No Graph token available. Provide Authorization: Bearer <token> or app-registration credentials (X-Maester-Client-Id / X-Maester-Client-Secret).'
        }

        $secureToken = ConvertTo-SecureString -String $graphTokenToUse -AsPlainText -Force
        Push-Location $invocationTempDir
        try {
            Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
        }
        finally {
            Pop-Location
        }

        # ── 3.1 Resolve tenant domain name ────────────────────────────────
        # Connect-IPPSSession's -Organization parameter requires the tenant's
        # initial verified domain (e.g. contoso.onmicrosoft.com), NOT a GUID.
        # Passing a GUID causes the SCC endpoint to return HTML error pages
        # instead of JSON → "Unexpected character encountered while parsing
        # value: <".  Exchange Online tolerates GUIDs, so this is only needed
        # for IPPS.
        $tenantDomain = $null
        if ($graphTokenToUse -and $TenantId) {
            try {
                $orgResp = Invoke-RestMethod `
                    -Uri         'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains' `
                    -Headers     @{ 'Authorization' = "Bearer $graphTokenToUse" } `
                    -ErrorAction Stop
                # Find the initial *.onmicrosoft.com domain
                $tenantDomain = ($orgResp.value[0].verifiedDomains |
                    Where-Object { $_.isInitial -eq $true } |
                    Select-Object -First 1).name
                if ($tenantDomain) {
                    Write-Host "[maester-runner] Resolved tenant domain: $tenantDomain"
                }
                else {
                    Write-Warning 'Tenant domain resolution returned no initial domain — IPPS may fail.'
                }
            }
            catch {
                Write-Warning "Failed to resolve tenant domain: $($_.Exception.Message)"
            }
        }

        # ── 3a. Connect to Exchange Online (OPTIONAL — app-only) ────────────
        # Uses client_credentials grant to obtain an app-only EXO token.
        # IMPORTANT: EXO module v3.9+ changed -AccessToken from SecureString
        # to plain String.  Passing a SecureString causes PowerShell to
        # bind the literal text "System.Security.SecureString" → 401.
        # Prerequisites (provisioned by PipePal):
        #   • Exchange.ManageAsApp application permission (admin consent)
        #   • Exchange Administrator Entra ID role assigned to the SP
        #   Note: Role propagation can take 5–30 minutes after initial provisioning;
        #   re-run the tests if this fails immediately after app creation.
        $exchangeConnected = $false
        $exchangeError     = $null
        $exoTokenRaw       = $null
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            try {
                $exoTokenRaw = Get-ClientCredentialToken `
                    -TenantId     $TenantId `
                    -ClientId     $MaesterClientId `
                    -ClientSecret $MaesterClientSecret `
                    -Scope        'https://outlook.office365.com/.default'
                Connect-ExchangeOnline `
                    -AccessToken  $exoTokenRaw `
                    -Organization $TenantId `
                    -ShowBanner:$false `
                    -ErrorAction Stop
                $exchangeConnected = $true
                Write-Host "[maester-runner] Exchange Online connected via app-only token (org: $TenantId)."
            }
            catch {
                $exchangeError = $_.Exception.Message
                Write-Warning "Exchange Online connection failed: $exchangeError"
            }
        }

        # ── 3a2. Connect to Security & Compliance (IPPS Session — OPTIONAL) ──
        # Security & Compliance tests require a SEPARATE Connect-IPPSSession call.
        # IPPS shares the Exchange Online infrastructure — the SCC PowerShell
        # endpoint accepts tokens scoped to https://outlook.office365.com.
        # Re-using the EXO token avoids needing a separate resource grant on
        # the compliance audience (which the app registration may not have).
        # See: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
        $securityComplianceConnected = $false
        $securityComplianceError     = $null
        # IPPS requires the tenant domain name, not a GUID, for -Organization.
        $ippsOrg = if ($tenantDomain) { $tenantDomain } else { $TenantId }
        if ($exoTokenRaw -and $TenantId) {
            try {
                Connect-IPPSSession `
                    -AccessToken  $exoTokenRaw `
                    -Organization $ippsOrg `
                    -ShowBanner:$false `
                    -ErrorAction Stop
                $securityComplianceConnected = $true
                Write-Host "[maester-runner] Security & Compliance (IPPS) connected via EXO token (org: $ippsOrg)."
            }
            catch {
                $securityComplianceError = $_.Exception.Message
                Write-Warning "Security & Compliance (IPPS) connection failed: $securityComplianceError"
            }
        }
        elseif ($MaesterClientId -and $MaesterClientSecret -and $TenantId -and -not $exoTokenRaw) {
            # EXO token wasn't acquired — try standalone with compliance audience
            try {
                $ippsTokenRaw = Get-ClientCredentialToken `
                    -TenantId     $TenantId `
                    -ClientId     $MaesterClientId `
                    -ClientSecret $MaesterClientSecret `
                    -Scope        'https://ps.compliance.protection.outlook.com/.default'
                Connect-IPPSSession `
                    -AccessToken  $ippsTokenRaw `
                    -Organization $ippsOrg `
                    -ShowBanner:$false `
                    -ErrorAction Stop
                $securityComplianceConnected = $true
                Write-Host "[maester-runner] Security & Compliance (IPPS) connected via compliance token (org: $ippsOrg)."
            }
            catch {
                $securityComplianceError = $_.Exception.Message
                Write-Warning "Security & Compliance (IPPS) connection failed: $securityComplianceError"
            }
        }

        # ── 3b. Connect to Microsoft Teams (OPTIONAL) ────────────────────────
        # MicrosoftTeams module requires TWO access tokens for app-only auth:
        #   1. Microsoft Graph token  (aud: https://graph.microsoft.com)
        #   2. Teams resource token   (aud: 48ac35b8-9aa8-4d74-927d-1f4a14a0b239)
        #
        # Per Microsoft docs, NO API permissions should be configured on the
        # "Skype and Teams Tenant Admin API" service principal. RBAC comes
        # from the directory role (Teams Administrator) assigned to the app.
        #
        # References:
        #   https://learn.microsoft.com/en-us/microsoftteams/teams-powershell-application-authentication
        $teamsConnected = $false
        $teamsError     = $null
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            try {
                # Both tokens MUST be the same type (both app-only via
                # client_credentials).  $graphTokenToUse may be a delegated
                # (user) token forwarded by the caller, so we always acquire
                # a fresh app-only Graph token for the Teams connection.
                $teamsGraphToken = Get-ClientCredentialToken `
                    -TenantId     $TenantId `
                    -ClientId     $MaesterClientId `
                    -ClientSecret $MaesterClientSecret `
                    -Scope        'https://graph.microsoft.com/.default'

                # Acquire Teams API resource token via client_credentials
                $teamsTokenRaw = Get-ClientCredentialToken `
                    -TenantId     $TenantId `
                    -ClientId     $MaesterClientId `
                    -ClientSecret $MaesterClientSecret `
                    -Scope        '48ac35b8-9aa8-4d74-927d-1f4a14a0b239/.default'

                if (-not $teamsGraphToken -or -not $teamsTokenRaw) {
                    throw 'Failed to acquire Teams tokens (Graph + resource)'
                }

                # Pass BOTH app-only tokens: Graph (element 0) + Teams resource (element 1)
                # Docs example omits -TenantId; module infers it from the tokens.
                Connect-MicrosoftTeams `
                    -AccessTokens @($teamsGraphToken, $teamsTokenRaw) `
                    -ErrorAction Stop
                $teamsConnected = $true
                Write-Host '[maester-runner] Microsoft Teams connected via Graph + Teams resource tokens.'
            }
            catch {
                $teamsError = $_.Exception.Message
                Write-Warning "Microsoft Teams connection failed: $teamsError"
            }
        }

        # ── 3c. Connect to Azure (OPTIONAL — service principal) ──────────────
        # Enables Azure resource tests (CIS Azure, XSPM, etc.).
        # Uses service principal credentials with the tenant ID.
        # The app registration must have Reader role (or equivalent) on the
        # Azure subscription / management group being tested.
        $azureConnected = $false
        $azureError     = $null
        if ($MaesterClientId -and $MaesterClientSecret -and $TenantId) {
            try {
                $azureSecureSecret = ConvertTo-SecureString $MaesterClientSecret -AsPlainText -Force
                $azureCred = New-Object System.Management.Automation.PSCredential(
                    $MaesterClientId, $azureSecureSecret
                )
                Connect-AzAccount `
                    -ServicePrincipal `
                    -Credential $azureCred `
                    -Tenant     $TenantId `
                    -ErrorAction Stop | Out-Null
                $azureConnected = $true
                Write-Host '[maester-runner] Azure connected via service principal.'
            }
            catch {
                $azureError = $_.Exception.Message
                Write-Warning "Azure connection failed: $azureError"
            }
        }

        # ── 3d. Collect connection diagnostics ──────────────────────────────
        # Track which services connected so the frontend can display it.
        $connectionDiagnostics = [ordered]@{
            graph                   = $true  # Graph is required; we'd have thrown if it failed
            exchangeOnline          = $exchangeConnected
            exchangeError           = $exchangeError
            securityCompliance      = $securityComplianceConnected
            securityComplianceError = $securityComplianceError
            teams                   = $teamsConnected
            teamsError              = $teamsError
            azure                   = $azureConnected
            azureError              = $azureError
            moeraDomain             = $tenantDomain
        }
        Write-Host "[maester-runner] Connection summary: Graph=OK, Exchange=$exchangeConnected, IPPS=$securityComplianceConnected, Teams=$teamsConnected, Azure=$azureConnected"

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
        if ($securityComplianceConnected) {
            # Disconnect-IPPSSession is not a real cmdlet; the EXO module manages
            # the SCC connection alongside Exchange.  Disconnecting Exchange
            # (above) also tears down the IPPS session, but we call the
            # ExchangeOnline disconnect again just in case they were separate.
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
        if ($teamsConnected) {
            Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue
        }
        if ($azureConnected) {
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
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

            # Use Id already computed by ConvertTo-MtMaesterResult (e.g. "MT.1001"),
            # fall back to legacy tag-based extraction for edge cases.
            if ($test.Id) {
                $testId = $test.Id
            } else {
                $testId = $test.Tag |
                    Where-Object { $_ -match '^[A-Z]+(\.[A-Z0-9]+)+$' } |
                    Select-Object -First 1
                if (-not $testId) { $testId = $test.Name -replace '\s+', '-' }
            }

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
                helpUrl     = if ($test.HelpUrl)     { [string]$test.HelpUrl }     else { $null }
                # Rich detail from Add-MtTestResultDetail (description, result markdown, skip context)
                resultDetail = if ($test.ResultDetail) {
                    [ordered]@{
                        description    = if ($test.ResultDetail.TestDescription) { [string]$test.ResultDetail.TestDescription } else { $null }
                        resultMarkdown = if ($test.ResultDetail.TestResult)      { [string]$test.ResultDetail.TestResult }      else { $null }
                        skippedBecause = if ($test.ResultDetail.TestSkipped)     { [string]$test.ResultDetail.TestSkipped }     else { $null }
                        skippedReason  = if ($test.ResultDetail.SkippedReason)   { [string]$test.ResultDetail.SkippedReason }   else { $null }
                        investigate    = if ($test.ResultDetail.TestInvestigate) { [bool]$test.ResultDetail.TestInvestigate }   else { $false }
                        service        = if ($test.ResultDetail.Service)         { [string]$test.ResultDetail.Service }         else { $null }
                    }
                } else { $null }
            }
        }

        # ── 9a. Synthesize missing tests as NotRun ────────────────────────────
        # Some tests defined in maester-config.json are never added to
        # $maesterJson.Tests by Pester — typically because a required service
        # connection (Exchange, Teams, Azure) was unavailable, or because Pester
        # tag-discovery skipped them for a tenant-specific reason.
        # We load the config and append a synthetic NotRun entry for every
        # expected test that did not appear in the Pester output, so the
        # totalCount always equals the full inventory count for the requested suites.
        #
        # ID-mismatch guard: Pester occasionally emits a fallback name-based ID
        # (e.g. "Enable-Conditional-Access-...") for a test whose $test.Id is
        # null and whose tags don't match the MT.* pattern.  Such a phantom test
        # would be in $flatTests but absent from the config, causing one extra
        # NotRun to be synthesised (totalCount = inventoryCount + 1).  We prevent
        # this by computing notRunToAdd = configExpected - matchedPester so that
        # phantom Pester tests consume the "slot" of their unidentified config
        # counterpart, keeping totalCount exactly equal to the inventory count.
        $mcConfigPath = Join-Path $TestsPath 'maester-config.json'
        if ($TestsPath -and (Test-Path $mcConfigPath)) {
            try {
                $mcConfig = Get-Content $mcConfigPath -Raw | ConvertFrom-Json

                # Suite-ID → test-ID prefix mapping (mirrors inventory-builder.ps1)
                $suitePrefix = @{
                    maester = 'MT.'
                    eidsca  = 'EIDSCA.'
                    cis     = 'CIS.'
                    cisa    = 'CISA.'
                    orca    = 'ORCA.'
                }

                # Determine which prefixes are in scope for this run
                $activePrefixes = if ($requestedSuites.Count -gt 0) {
                    @($requestedSuites |
                        Where-Object { $suitePrefix.ContainsKey($_) } |
                        ForEach-Object { $suitePrefix[$_] })
                } else {
                    @($suitePrefix.Values)   # all suites → all prefixes
                }

                # Collect only the in-scope config entries (mirrors inventory count)
                $inScopeConfigTests = @($mcConfig.TestSettings | Where-Object {
                    $t = $_
                    $activePrefixes.Count -eq 0 -or ($activePrefixes | Where-Object { $t.Id.StartsWith($_) })
                })

                # Build a fast lookup of config IDs (used to check which
                # config entries are already covered by a Pester result)
                $configIdSet = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($t in $inScopeConfigTests) { $null = $configIdSet.Add($t.Id) }

                # Build a fast lookup of IDs already present in $flatTests
                $executedIds = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($t in $flatTests) { $null = $executedIds.Add($t.id) }

                # Cap NotRun additions to (configExpected - pesterTotal).
                # A phantom Pester test (fallback name-based ID, not in config) still
                # occupies a "slot" in totalCount, so budget = configCount - pesterCount
                # keeps totalCount == inventory count regardless of ID mismatches.
                # Using (configCount - matchedPesterCount) would give budget=12 when
                # 1 phantom exists (312 matched + 1 phantom = 313 pester, 12 unmatched
                # config entries) → totalCount = 313+12 = 325.  Correct formula below.
                $pesterCountBeforeSynthesis = $flatTests.Count
                $notRunBudget = [Math]::Max(0, $inScopeConfigTests.Count - $pesterCountBeforeSynthesis)
                $notRunAdded  = 0

                # Append a NotRun entry for every expected test that Pester missed,
                # respecting the budget so totalCount == inventory count.
                foreach ($t in $inScopeConfigTests) {
                    if ($notRunAdded -ge $notRunBudget) { break }
                    if (-not $executedIds.Contains($t.Id)) {
                        $flatTests += [ordered]@{
                            id           = $t.Id
                            name         = if ($t.Title)    { $t.Title }    else { $t.Id }
                            result       = 'NotRun'
                            duration     = 0
                            severity     = if ($t.Severity) { $t.Severity } else { 'Info' }
                            category     = ''
                            block        = ''
                            errorRecord  = $null
                            helpUrl      = $null
                            resultDetail = $null
                        }
                        $notRunAdded++
                    }
                }
                Write-Host "[maester-runner] Synthesized $notRunAdded missing tests as NotRun (budget: $notRunBudget, config: $($inScopeConfigTests.Count), pester: $($executedIds.Count))."
            } catch {
                Write-Warning "[maester-runner] Could not synthesize missing tests: $($_.Exception.Message)"
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
            errorCount     = ($flatTests | Where-Object { $_.result -eq 'Error'   }).Count
            durationMs     = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
            timestamp      = if ($maesterJson.ExecutedAt) { $maesterJson.ExecutedAt }
                             else { $runStart.ToString('o') }
            suitesRun      = $Suites
            severityFilter = $Severities
            # Connection diagnostics — tells the UI which services connected
            connections    = $connectionDiagnostics
            tests          = $flatTests
        }

        # ── 10. Write result to SQLite ────────────────────────────────────────
        $resultJson = $summary | ConvertTo-Json -Depth 12 -Compress
        $durationMs = [math]::Round(($runEnd - $runStart).TotalMilliseconds)
        Update-Job -Status 'completed' -Result $resultJson -ErrorMsg $null -DurationMs $durationMs

    }
    catch {
        Disconnect-MgGraph          -ErrorAction SilentlyContinue
        Disconnect-ExchangeOnline   -Confirm:$false -ErrorAction SilentlyContinue
        Disconnect-MicrosoftTeams   -ErrorAction SilentlyContinue
        try { Disconnect-AzAccount  -ErrorAction SilentlyContinue | Out-Null } catch { }
        # Sanitize error message — never leak file paths, stack traces, or secrets
        $errMsg = $_.Exception.Message
        # Strip file paths
        $errMsg = $errMsg -replace '[A-Za-z]:\\[^\s"'']+', '[path]'
        $errMsg = $errMsg -replace '/[^\s"'']*\.(ps1|psm1|psd1|dll|exe)', '[path]'
        # Strip anything that looks like a token/secret (long base64-like strings)
        $errMsg = $errMsg -replace '[A-Za-z0-9+/=]{40,}', '[redacted]'
        # Truncate to prevent DB bloat
        if ($errMsg.Length -gt 500) { $errMsg = $errMsg.Substring(0, 500) + '...' }
        try { Update-Job -Status 'failed' -Result $null -ErrorMsg $errMsg -DurationMs 0 } catch { }
    }
    finally {
        # ── 11. Cleanup temp directory ────────────────────────────────────────
        if ($invocationTempDir -and (Test-Path $invocationTempDir)) {
            Remove-Item -Path $invocationTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
