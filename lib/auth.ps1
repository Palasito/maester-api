# lib/auth.ps1 — Authentication & authorization helpers
#
# Two-layer auth:
#   Layer 1 — API key: X-Functions-Key or X-Api-Key header (all routes except /health)
#   Layer 2 — Bearer token: Authorization header (POST only, per-request)
#
# Bearer token is the MSAL workspace token (BASE scopes) used for proxy-route auth.
# The runner acquires all service tokens itself via client_credentials grant.

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
