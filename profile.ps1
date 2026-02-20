# Azure Functions profile.ps1
# This script runs on cold start and every time a new worker is spawned.
# It's ideal for one-time setup tasks such as setting module preferences
# or authenticating with managed identity.

# Authenticate with Azure PowerShell using MSI (if needed for Key Vault etc.)
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    # Connect-AzAccount -Identity | Out-Null
}

# Suppress verbose to keep logs clean during module auto-loading
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
