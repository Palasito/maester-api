# fix-pode-closures.ps1
# ═══════════════════════════════════════════════════════════════════════════════
# Patches Pode 2.12.1 to fix two memory leak sources:
#
# 1. GetNewClosure() per invocation — caches closures so each ScriptBlock's
#    SessionState snapshot is created once, not on every call.
#
# 2. Invoke-PodeGC (GC.Collect) after every timer tick — forces full Gen-2 GC
#    ~138 times/hour, which prematurely promotes transient Gen-0 objects into
#    Gen-2 where they survive indefinitely. This is the PRIMARY cause of the
#    ~3 MB/hour monotonic memory growth and the gen0≈gen1≈gen2 GC pattern.
#    Fix: Replace the forced GC.Collect with a no-op comment.
# ═══════════════════════════════════════════════════════════════════════════════

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$podeBase = (Get-Module -ListAvailable Pode | Select-Object -First 1).ModuleBase
if (-not $podeBase) { throw 'Pode module not found' }
Write-Host "[patch] Pode module at: $podeBase"

# Helper: normalise line endings to LF for reliable string matching
# (Pode ships with LF; this script may have CRLF from Windows)
function Normalize-LF ([string]$s) { $s -replace "`r`n", "`n" }

# ─── Patch 1: Private/Timers.ps1 ────────────────────────────────────────────
# Cache the closure on the Timer object so GetNewClosure() runs once per timer,
# not once per tick (~138 ticks/hour across 4 timers).
$timersFile = Join-Path $podeBase 'Private/Timers.ps1'
$content = Normalize-LF (Get-Content $timersFile -Raw)

$oldTimer = Normalize-LF '        Invoke-PodeScriptBlock -ScriptBlock $Timer.Script.GetNewClosure() -Arguments $_args -UsingVariables $Timer.UsingVariables -Scoped -Splat -NoNewClosure'

$newTimer = Normalize-LF @'
        # Cache closure per timer to prevent per-tick memory leak
        if (-not $Timer._CachedScript) { $Timer._CachedScript = $Timer.Script.GetNewClosure() }
        Invoke-PodeScriptBlock -ScriptBlock $Timer._CachedScript -Arguments $_args -UsingVariables $Timer.UsingVariables -Scoped -Splat -NoNewClosure
'@

if ($content.Contains($oldTimer)) {
    $content = $content.Replace($oldTimer, $newTimer)
    Set-Content $timersFile -Value $content -NoNewline
    Write-Host '[patch] Timers.ps1: cached timer closure (1 GetNewClosure per timer lifetime)'
}
else {
    Write-Host '[patch] Timers.ps1: target string not found — already patched or version mismatch'
}

# ─── Patch 2: Public/Utilities.ps1 — Invoke-PodeScriptBlock ─────────────────
# Cache closures keyed by ScriptBlock object identity. Routes, middleware, and
# auth handlers reuse the same ScriptBlock object on every request, so the
# cache stays small (bounded by number of registered handlers, typically <30).
$utilFile = Join-Path $podeBase 'Public/Utilities.ps1'
$content = Normalize-LF (Get-Content $utilFile -Raw)

$oldUtil = Normalize-LF @'
    # if new closure needed, create it
    if (!$NoNewClosure) {
        $ScriptBlock = ($ScriptBlock).GetNewClosure()
    }
'@

$newUtil = Normalize-LF @'
    # if new closure needed, create or retrieve cached closure
    # (caching prevents ~5 KB SessionState leak per invocation)
    if (!$NoNewClosure) {
        if (-not $script:_PodeClosureCache) {
            $script:_PodeClosureCache = [System.Collections.Generic.Dictionary[int,scriptblock]]::new()
        }
        $_ck = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ScriptBlock)
        if (-not $script:_PodeClosureCache.ContainsKey($_ck)) {
            $script:_PodeClosureCache[$_ck] = ($ScriptBlock).GetNewClosure()
        }
        $ScriptBlock = $script:_PodeClosureCache[$_ck]
    }
'@

if ($content.Contains($oldUtil)) {
    $content = $content.Replace($oldUtil, $newUtil)
    Set-Content $utilFile -Value $content -NoNewline
    Write-Host '[patch] Utilities.ps1: cached scriptblock closures in Invoke-PodeScriptBlock'
}
else {
    Write-Host '[patch] Utilities.ps1: target string not found — already patched or version mismatch'
}

# ─── Patch 3: Private/Timers.ps1 — Remove Invoke-PodeGC from finally block ──
# Pode calls [System.GC]::Collect() (via Invoke-PodeGC) in the finally block
# of Invoke-PodeInternalTimer — i.e. after EVERY timer tick. With 4 timers
# this forces ~138 full Gen-2 garbage collections per hour.
#
# Impact: forced GC.Collect() prematurely promotes Gen-0/Gen-1 objects to Gen-2
# before generational GC can cheaply reclaim them. Gen-2 objects have higher
# survival thresholds, so a fraction "stick" and cause monotonic RAM growth.
# This also explains why gen0 ≈ gen1 ≈ gen2 collection counts — every GC is
# a forced full collection.
#
# Fix: Comment out Invoke-PodeGC in the timer finally block. Let .NET's
# workstation GC use its natural generational strategy.
$timersContent = Normalize-LF (Get-Content $timersFile -Raw)

$oldGC = Normalize-LF @'
    finally {
        Invoke-PodeGC
    }
'@

$newGC = Normalize-LF @'
    finally {
        # Invoke-PodeGC removed: forced GC.Collect() after every timer tick
        # promotes transient objects to Gen-2 prematurely, causing ~3 MB/hour
        # monotonic memory growth. Let .NET manage GC timing naturally.
    }
'@

if ($timersContent.Contains($oldGC)) {
    $timersContent = $timersContent.Replace($oldGC, $newGC)
    Set-Content $timersFile -Value $timersContent -NoNewline
    Write-Host '[patch] Timers.ps1: removed Invoke-PodeGC from timer finally block'
}
else {
    Write-Host '[patch] Timers.ps1: Invoke-PodeGC target not found — already patched or version mismatch'
}

Write-Host '[patch] All Pode patches complete.'
