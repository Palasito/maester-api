# install-modules.ps1
# Runs during Docker image build to pre-bake PowerShell modules into the image.
# Executed as: pwsh -NoProfile -NonInteractive -File /install-modules.ps1
#
# Pattern inspired by https://maester.dev/docs/monitoring/azure-container-app-job

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

# ── Trust PSGallery ───────────────────────────────────────────────────────────
# The base image ships with PSGallery as Untrusted. Install-Module will prompt
# (and get no input in a non-interactive build) unless we trust it first.
Write-Host '[install-modules] Trusting PSGallery...'
Import-Module PowerShellGet -ErrorAction SilentlyContinue
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop

# ── Install modules to system scope ──────────────────────────────────────────
# AllUsers scope → /usr/local/share/powershell/Modules/ (standard Linux path).
#
# Modules included:
#   Pode                            — lightweight PowerShell HTTP server
#   Pester                          — test runner (Maester dependency)
#   Microsoft.Graph.Authentication  — Graph API connection
#   ExchangeOnlineManagement        — Exchange Online tests (Maester ORCA suite)
#   MicrosoftTeams                  — Teams configuration tests
#   PSSQLite                        — SQLite data access for job persistence
#   Maester                         — M365 security test framework
#   NOTE: Microsoft.PowerShell.ThreadJob is NOT installed — we use Start-Job
#   (child process) instead of Start-ThreadJob (thread in same process) so
#   that module memory is fully reclaimed by the OS after each test run.
$modules = @(
    'Pode'
    'Pester'
    'Microsoft.Graph.Authentication'
    'ExchangeOnlineManagement'
    'MicrosoftTeams'
    'PSSQLite'
    'Maester'
)

foreach ($mod in $modules) {
    Write-Host "[install-modules] Installing $mod ..."
    Install-Module -Name $mod `
        -Repository PSGallery `
        -Scope AllUsers `
        -Force `
        -AllowClobber `
        -SkipPublisherCheck `
        -ErrorAction Stop
    Write-Host "[install-modules] $mod OK."
}

Write-Host ''
Write-Host '[install-modules] Installed modules:'
Get-ChildItem /usr/local/share/powershell/Modules -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $versions = (Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue).Name -join ', '
    Write-Host "  $($_.Name) [$versions]"
}

# ── Install Maester tests at build time ──────────────────────────────────────
# Downloads the latest test definitions from GitHub into /app/maester-tests.
# This ensures the image has reasonably fresh tests even without network at startup.
# server.ps1 will attempt to refresh these at container boot (best-effort).
Write-Host '[install-modules] Installing Maester test definitions to /app/maester-tests ...'
try {
    Import-Module Maester -ErrorAction Stop
    Install-MaesterTests -Path '/app/maester-tests' -ErrorAction Stop
    $suiteCount = (Get-ChildItem /app/maester-tests -Directory -ErrorAction SilentlyContinue).Count
    Write-Host "[install-modules] Maester tests installed ($suiteCount suite directories)."
} catch {
    Write-Host "[install-modules] WARNING: Install-MaesterTests failed: $($_.Exception.Message)"
    Write-Host '[install-modules] Tests will use module-bundled fallback at runtime.'
}

Write-Host '[install-modules] Done.'
