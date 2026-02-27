# lib/auth.ps1 — Authentication & authorization helpers
#
# Two-layer auth:
#   Layer 1 — API key: X-Functions-Key or X-Api-Key header (all routes except /health)
#   Layer 2 — Bearer token: Authorization header (POST only, per-request)
#
# Bearer token is the MSAL workspace token (BASE scopes) used for proxy-route auth.
# The runner acquires all service tokens itself via client_credentials grant.
#
# Security principles:
#   - Fail-closed: missing API key config → deny all (never fail-open)
#   - Constant-time comparison for API keys (prevent timing attacks)
#   - Bearer token extracted but NOT validated here — downstream services
#     (Microsoft Graph, Exchange, etc.) validate the token themselves
#   - Error messages never leak internal details

# ── API Key validation ────────────────────────────────────────────────────────

function Test-ApiKey {
    <#
    .SYNOPSIS  Validate the request API key against $env:MAESTER_API_KEY.
               Accepts both X-Functions-Key (backward compat) and X-Api-Key.
               FAIL-CLOSED: If no API key is configured, ALL requests are denied.
    .OUTPUTS   [bool] $true if valid, $false otherwise.
    #>
    param([Parameter(Mandatory)] $Headers)

    $expected = $env:MAESTER_API_KEY
    if (-not $expected) {
        # SECURITY: Fail-closed — no key configured means deny all.
        # This prevents accidental exposure if the env var is missing in production.
        Write-Warning '[auth] MAESTER_API_KEY not configured — denying request (fail-closed).'
        return $false
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

# ── Bearer token extraction ───────────────────────────────────────────────────

function Get-BearerToken {
    <#
    .SYNOPSIS  Extract raw Bearer token from Authorization header.
               No JWT validation is performed here — the token is passed through
               to downstream services (Microsoft Graph, Exchange, etc.) which
               validate it themselves.
    .OUTPUTS   [string] The token string, or $null if missing/malformed.
    #>
    param([Parameter(Mandatory)] $Headers)

    $authHeader = $Headers['Authorization']
    if (-not $authHeader) { return $null }
    if (-not $authHeader.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $token = $authHeader.Substring(7).Trim()
    if ($token.Length -lt 10) { return $null }   # sanity check — reject obviously empty/tiny values

    return $token
}

# ── Input validation helpers ──────────────────────────────────────────────────

function Test-ValidTenantId {
    <#
    .SYNOPSIS  Validate that a tenantId is a well-formed GUID.
    .OUTPUTS   [bool] $true if valid GUID format, $false otherwise.
    #>
    param([Parameter(Mandatory)][string] $TenantId)

    $guidResult = [guid]::Empty
    return [guid]::TryParse($TenantId, [ref]$guidResult)
}

function Get-SanitizedErrorMessage {
    <#
    .SYNOPSIS  Return a safe error message that doesn't leak internal details.
               Strips file paths, stack traces, and module internals.
    .OUTPUTS   [string] A sanitized error message safe for client consumption.
    #>
    param([string] $ErrorMessage)

    if (-not $ErrorMessage) { return 'An internal error occurred.' }

    # Remove file paths (Windows and Linux)
    $sanitized = $ErrorMessage -replace '[A-Za-z]:\\[^\s"'']+', '[path]'
    $sanitized = $sanitized   -replace '/[^\s"'']*\.(ps1|psm1|psd1|dll|exe)', '[path]'

    # Remove stack trace lines
    $sanitized = $sanitized -replace 'at\s+\S+,\s+[^\r\n]+', ''
    $sanitized = $sanitized -replace 'At line:\d+.*', ''

    # Remove module version/path info
    $sanitized = $sanitized -replace '\d+\.\d+\.\d+[\.\d]*', '[version]'

    # Trim excessive whitespace
    $sanitized = ($sanitized -replace '\s+', ' ').Trim()

    # Truncate overly long messages
    if ($sanitized.Length -gt 500) {
        $sanitized = $sanitized.Substring(0, 500) + '...'
    }

    return $sanitized
}
