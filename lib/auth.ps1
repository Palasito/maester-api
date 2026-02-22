# lib/auth.ps1 — Authentication & authorization helpers
#
# Two-layer auth:
#   Layer 1 — API key: X-Functions-Key or X-Api-Key header (all routes except /health)
#   Layer 2 — Bearer token: Authorization header (POST only, per-request)
#
# Phase 1: Graph token only (Authorization header)
# Phase 3: + Exchange token (X-Exchange-Token) + Teams token (X-Teams-Token)

# ── API Key validation ────────────────────────────────────────────────────────

function Test-ApiKey {
    <#
    .SYNOPSIS  Validate the request API key against $env:MAESTER_API_KEY.
               Accepts both X-Functions-Key (backward compat) and X-Api-Key.
    .OUTPUTS   [bool] $true if valid, $false otherwise.
    #>
    param([Parameter(Mandatory)] $Headers)

    $expected = $env:MAESTER_API_KEY
    if (-not $expected) {
        # No key configured → allow all (dev/local mode)
        return $true
    }

    $key = $Headers['X-Functions-Key']
    if (-not $key) { $key = $Headers['X-Api-Key'] }
    if (-not $key) { return $false }

    # Constant-time comparison to prevent timing attacks
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [System.Text.Encoding]::UTF8.GetBytes($key),
        [System.Text.Encoding]::UTF8.GetBytes($expected)
    )
}

# ── Bearer token extraction ──────────────────────────────────────────────────

function Get-BearerToken {
    <#
    .SYNOPSIS  Extract raw JWT from Authorization: Bearer <token> header.
    .OUTPUTS   [string] The token, or $null if missing/malformed.
    #>
    param([Parameter(Mandatory)] $Headers)

    $authHeader = $Headers['Authorization']
    if (-not $authHeader) { return $null }
    if (-not $authHeader.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $token = $authHeader.Substring(7).Trim()
    if ($token.Length -lt 10) { return $null }   # sanity check
    return $token
}

# ── Service token bundle (Phase 1: Graph only) ───────────────────────────────

function Get-ServiceTokens {
    <#
    .SYNOPSIS  Return a hashtable of per-service tokens extracted from headers.
               Phase 1: only Graph (from Authorization header).
               Phase 3: adds Exchange (X-Exchange-Token) and Teams (X-Teams-Token).
    #>
    param([Parameter(Mandatory)] $Headers)

    return @{
        Graph    = Get-BearerToken -Headers $Headers         # REQUIRED
        Exchange = $Headers['X-Exchange-Token']               # Phase 3 — optional
        Teams    = $Headers['X-Teams-Token']                  # Phase 3 — optional
    }
}
