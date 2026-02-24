# lib/inventory-builder.ps1 — Build a live Maester test inventory
#
# Reads maester-config.json (single source of truth for test metadata) and
# scans the directory structure to map MT.* tests to subcategories.
# Returns an ordered hashtable matching the MaesterTestInventory TypeScript
# interface consumed by PipePal.
#
# Called once at server startup; the result is cached for the container's
# lifetime because tests are only refreshed at boot (Install-MaesterTests).

function Build-MaesterInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TestsPath
    )

    Write-Host "[inventory-builder] Building inventory from $TestsPath ..."

    # ── 1. Read maester-config.json ──────────────────────────────────────────
    $configPath = Join-Path $TestsPath 'maester-config.json'
    if (-not (Test-Path $configPath)) {
        throw "maester-config.json not found at $configPath"
    }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $tests  = $config.TestSettings
    Write-Host "[inventory-builder] Loaded $($tests.Count) test definitions from config."

    # ── 2. Build MT.* ID → subcategory mapping from directory structure ──────
    #
    # The Maester/ directory contains subdirectories (Entra, Azure, Intune,
    # Defender, Exchange, Teams, Drift) each with .Tests.ps1 files.
    # We parse each file for MT.XXXX patterns to build the lookup.
    # Tests not found in any subdirectory are assigned "General".
    $subcategoryMap = @{}

    $maesterDir = Join-Path $TestsPath 'Maester'
    $xspmDir    = Join-Path $TestsPath 'XSPM'

    # Scan Maester/ subdirectories
    if (Test-Path $maesterDir) {
        # First, handle .Tests.ps1 files directly in Maester/ (not in subdirs)
        foreach ($file in (Get-ChildItem $maesterDir -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue)) {
            $content   = Get-Content $file.FullName -Raw
            $idMatches = [regex]::Matches($content, 'MT\.\d+')
            foreach ($m in $idMatches) {
                if (-not $subcategoryMap.ContainsKey($m.Value)) {
                    $subcategoryMap[$m.Value] = 'General'
                }
            }
        }

        # Then scan each subdirectory
        foreach ($subDir in (Get-ChildItem $maesterDir -Directory -ErrorAction SilentlyContinue)) {
            # Map directory names to display-friendly subcategory names
            $displayName = switch ($subDir.Name) {
                'Drift' { 'General' }
                default { $subDir.Name }
            }

            foreach ($file in (Get-ChildItem $subDir.FullName -Filter '*.Tests.ps1' -File -Recurse -ErrorAction SilentlyContinue)) {
                $content   = Get-Content $file.FullName -Raw
                $idMatches = [regex]::Matches($content, 'MT\.\d+')
                foreach ($m in $idMatches) {
                    if (-not $subcategoryMap.ContainsKey($m.Value)) {
                        $subcategoryMap[$m.Value] = $displayName
                    }
                }
            }
        }
    }

    # Scan XSPM/ directory (uses MT.* IDs, mapped to "General")
    if (Test-Path $xspmDir) {
        foreach ($file in (Get-ChildItem $xspmDir -Filter '*.Tests.ps1' -File -Recurse -ErrorAction SilentlyContinue)) {
            $content   = Get-Content $file.FullName -Raw
            $idMatches = [regex]::Matches($content, 'MT\.\d+')
            foreach ($m in $idMatches) {
                if (-not $subcategoryMap.ContainsKey($m.Value)) {
                    $subcategoryMap[$m.Value] = 'General'
                }
            }
        }
    }

    Write-Host "[inventory-builder] Mapped $($subcategoryMap.Count) MT IDs to subcategories."

    # ── 3. Suite definitions ─────────────────────────────────────────────────
    $suiteDefs = [ordered]@{
        'maester' = @{
            name        = 'Maester Tests'
            description = 'Community-created security tests for Conditional Access, Entra ID, Intune, Exchange, Teams, Defender'
            prefix      = 'MT.'
        }
        'eidsca' = @{
            name        = 'EIDSCA Tests'
            description = 'Entra ID Security Config Analyzer — checks tenant configuration against security best practices'
            prefix      = 'EIDSCA.'
        }
        'cis' = @{
            name        = 'CIS Benchmark Tests'
            description = 'Center for Internet Security M365 Benchmark compliance checks'
            prefix      = 'CIS.'
        }
        'cisa' = @{
            name        = 'CISA SCuBA Tests'
            description = 'CISA Secure Cloud Business Applications — federal security baseline for Microsoft 365'
            prefix      = 'CISA.'
        }
        'orca' = @{
            name        = 'ORCA Tests'
            description = 'Office 365 Recommended Configuration Analyzer for Exchange Online Protection'
            prefix      = 'ORCA.'
        }
    }

    # ── 4. Group tests by suite ──────────────────────────────────────────────
    $suites = [System.Collections.ArrayList]::new()

    foreach ($suiteId in $suiteDefs.Keys) {
        $def        = $suiteDefs[$suiteId]
        $suiteTests = @($tests | Where-Object { $_.Id.StartsWith($def.prefix) })

        # Build test definition objects
        $testDefs = [System.Collections.ArrayList]::new()
        foreach ($t in $suiteTests) {
            $subcat = $null
            if ($suiteId -eq 'maester') {
                $subcat = if ($subcategoryMap.ContainsKey($t.Id)) {
                    $subcategoryMap[$t.Id]
                } else {
                    'General'
                }
            }
            $null = $testDefs.Add([ordered]@{
                id          = $t.Id
                title       = $t.Title
                severity    = $t.Severity
                subcategory = $subcat
            })
        }

        # Build subcategories for the Maester suite
        $subcategories = [System.Collections.ArrayList]::new()
        if ($suiteId -eq 'maester' -and $testDefs.Count -gt 0) {
            $grouped = $testDefs | Group-Object { $_.subcategory } | Sort-Object Name
            foreach ($g in $grouped) {
                $null = $subcategories.Add([ordered]@{
                    id        = "maester-$($g.Name.ToLower())"
                    name      = $g.Name
                    testCount = $g.Count
                })
            }
        }

        $null = $suites.Add([ordered]@{
            id             = $suiteId
            name           = $def.name
            description    = $def.description
            subcategories  = @($subcategories)
            testCount      = $testDefs.Count
            tests          = @($testDefs)
        })
    }

    # ── 5. Severity summary ──────────────────────────────────────────────────
    $sevGroups  = $tests | Group-Object Severity
    $sevSummary = [ordered]@{
        Critical = 0
        High     = 0
        Medium   = 0
        Low      = 0
        Info     = 0
    }
    foreach ($g in $sevGroups) {
        if ($sevSummary.Contains($g.Name)) {
            $sevSummary[$g.Name] = $g.Count
        }
    }

    # ── 6. Get Maester module version ────────────────────────────────────────
    $version = 'unknown'
    try {
        $mod = Get-Module Maester -ListAvailable -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($mod) { $version = $mod.Version.ToString() }
    } catch { }

    # ── 7. Build final inventory ─────────────────────────────────────────────
    $totalCount = ($suites | ForEach-Object { $_.testCount } | Measure-Object -Sum).Sum

    $inventory = [ordered]@{
        generatedAt     = [datetime]::UtcNow.ToString('o')
        version         = $version
        suites          = @($suites)
        severitySummary = $sevSummary
        totalTestCount  = [int]$totalCount
    }

    Write-Host "[inventory-builder] Inventory built: $totalCount tests across $($suites.Count) suites (Maester v$version)."
    return $inventory
}
