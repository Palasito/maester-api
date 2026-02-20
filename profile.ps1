# Azure Functions profile.ps1
# Runs on every cold start (new host process / worker spawn).
#
# Strategy: self-managed modules on persistent /home/site/modules/ storage.
# Managed dependencies (requirements.psd1) are disabled because the download
# they perform on each cold start adds 2-5 minutes before any request can be
# served. Instead we install once here — subsequent cold starts see the modules
# already on disk and skip installation entirely (< 1 second overhead).
#
# To upgrade a module: bump the version stamp in $MODULE_STAMP below and the
# next cold start will re-install everything fresh.

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ─── Persistent module path (Azure Files, survives restarts) ──────────────────
# Falls back to a temp directory when running locally (no /home mount).
$MODULES_PATH = if (Test-Path '/home') {
    '/home/site/modules'
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'az-func-modules'
}

# ─── Always register the path so every invocation (and every thread job) ──────
# can resolve the modules without an explicit Import-Module path argument.
# Thread jobs inherit process-level environment variables, so this covers them.
if ($env:PSModulePath -notlike "*$MODULES_PATH*") {
    $env:PSModulePath = $MODULES_PATH + [System.IO.Path]::PathSeparator + $env:PSModulePath
}

# ─── Version stamp ─────────────────────────────────────────────────────────────
# Change this string whenever you want to force a fresh module install
# (e.g. after a Maester major release or a security fix).
$MODULE_STAMP  = 'Pester-5 Graph.Authentication-2 Maester-0  2026-02-20'
$SENTINEL_FILE = Join-Path $MODULES_PATH '.installed'

$alreadyInstalled = (Test-Path $SENTINEL_FILE) -and
                    ((Get-Content $SENTINEL_FILE -Raw -ErrorAction SilentlyContinue).Trim() -eq $MODULE_STAMP)

if ($alreadyInstalled) {
    Write-Host "[profile] Modules up-to-date, skipping install."
} else {
    Write-Host "[profile] Installing modules to $MODULES_PATH ..."
    $null = New-Item -ItemType Directory -Path $MODULES_PATH -Force

    try {
        # Save-Module downloads into versioned sub-directories compatible with
        # PSModulePath auto-discovery (identical layout to Install-Module).
        Save-Module -Name Pester                         -Path $MODULES_PATH -Force -ErrorAction Stop
        Save-Module -Name Microsoft.Graph.Authentication -Path $MODULES_PATH -Force -ErrorAction Stop
        Save-Module -Name Maester                        -Path $MODULES_PATH -Force -ErrorAction Stop

        # Write sentinel only after all three succeed
        Set-Content -Path $SENTINEL_FILE -Value $MODULE_STAMP -Encoding UTF8 -Force
        Write-Host "[profile] Module installation complete."
    } catch {
        # Non-fatal: log and continue. The function will fail at invocation time
        # with a clear "module not found" error rather than silently here.
        Write-Warning "[profile] Module install failed: $($_.Exception.Message)"
    }
}
