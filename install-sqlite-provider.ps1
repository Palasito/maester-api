# install-sqlite-provider.ps1
# Runs during Docker image build to install Microsoft.Data.Sqlite + SQLitePCLRaw
# NuGet packages. These replace PSSQLite's System.Data.SQLite which requires a
# native SQLite.Interop.dll that doesn't ship for Alpine Linux.
#
# Installed DLLs go to /app/sqlite-libs/. The native libe_sqlite3.so goes to
# /usr/lib/ so the .NET runtime can find it via standard library search.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$dest    = '/app/sqlite-libs'
$tmpRoot = '/tmp/sqlitepkgs'
New-Item -ItemType Directory -Force -Path $dest, $tmpRoot | Out-Null

# ── NuGet packages to download ────────────────────────────────────────────────
# Using NuGet v3 flat-container API (direct download, no redirect).
$packages = @(
    @{ Name = 'microsoft.data.sqlite.core';          Version = '8.0.8' }
    @{ Name = 'sqlitepclraw.bundle_e_sqlite3';        Version = '2.1.6' }
    @{ Name = 'sqlitepclraw.core';                    Version = '2.1.6' }
    @{ Name = 'sqlitepclraw.lib.e_sqlite3';           Version = '2.1.6' }
    @{ Name = 'sqlitepclraw.provider.e_sqlite3';      Version = '2.1.6' }
)

foreach ($pkg in $packages) {
    $n = $pkg.Name; $v = $pkg.Version
    $url = "https://api.nuget.org/v3-flatcontainer/$n/$v/$n.$v.nupkg"
    $zip = Join-Path $tmpRoot "$n.zip"
    $dir = Join-Path $tmpRoot $n

    Write-Host "[install-sqlite] Downloading $n $v ..."
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Write-Host "[install-sqlite]   Downloaded $([math]::Round((Get-Item $zip).Length / 1KB)) KB"
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip
    # Debug: list DLLs and .so files in extracted package
    $dlls = Get-ChildItem -Path $dir -Include '*.dll','*.so' -Recurse -File
    Write-Host "[install-sqlite]   Found $($dlls.Count) binaries:"
    $dlls | ForEach-Object { Write-Host "    $($_.FullName -replace [regex]::Escape($tmpRoot), '')" }
}

# ── Copy managed DLLs (prefer net8.0, fall back to netstandard2.0) ────────────
$managedDlls = @(
    'Microsoft.Data.Sqlite.dll'
    'SQLitePCLRaw.batteries_v2.dll'
    'SQLitePCLRaw.core.dll'
    'SQLitePCLRaw.provider.e_sqlite3.dll'
)

foreach ($dll in $managedDlls) {
    $found = Get-ChildItem -Path $tmpRoot -Filter $dll -Recurse -File |
        Sort-Object { if ($_.DirectoryName -match 'net8') { 0 } elseif ($_.DirectoryName -match 'netstandard') { 1 } else { 2 } } |
        Select-Object -First 1

    if (-not $found) { throw "Could not find $dll in downloaded packages" }
    Write-Host "[install-sqlite]   $dll  ← $($found.DirectoryName | Split-Path -Leaf)"
    Copy-Item $found.FullName (Join-Path $dest $dll)
}

# ── Copy native library for Alpine Linux (musl-x64) ──────────────────────────
$nativeLib = Get-ChildItem -Path (Join-Path $tmpRoot 'sqlitepclraw.lib.e_sqlite3') `
    -Filter 'libe_sqlite3.so' -Recurse -File |
    Where-Object { $_.DirectoryName -match 'linux-musl-x64' } |
    Select-Object -First 1

if (-not $nativeLib) {
    # Fall back to generic linux-x64 (glibc)
    $nativeLib = Get-ChildItem -Path (Join-Path $tmpRoot 'sqlitepclraw.lib.e_sqlite3') `
        -Filter 'libe_sqlite3.so' -Recurse -File |
        Where-Object { $_.DirectoryName -match 'linux-x64' } |
        Select-Object -First 1
}
if (-not $nativeLib) { throw 'Could not find native libe_sqlite3.so for Linux' }

Write-Host "[install-sqlite]   libe_sqlite3.so  ← $($nativeLib.DirectoryName -replace '.*runtimes/', 'runtimes/')"
Copy-Item $nativeLib.FullName '/usr/lib/libe_sqlite3.so'

# ── Clean up temp files ───────────────────────────────────────────────────────
Remove-Item -Recurse -Force $tmpRoot

Write-Host '[install-sqlite] Installed assemblies:'
Get-ChildItem $dest -File | ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length/1KB)) KB)" }
Write-Host '[install-sqlite] Done.'
