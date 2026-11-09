$ErrorActionPreference = 'Stop'
$inputData = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
. (Join-Path $PSScriptRoot '../lib/maester-runner.ps1')
$config = $inputData.configuration
& $MaesterRunnerScriptBlock `
    -GraphToken $inputData.graphToken `
    -Suites $config.Suites `
    -Severities $config.Severity `
    -ExtraTags $config.Tags `
    -IncLongRunning $config.IncludeLongRunning `
    -IncPreview $config.IncludePreview `
    -TenantId $config.TenantId `
    -TestsPath $inputData.testsPath `
    -MaesterClientId $inputData.clientId `
    -MaesterClientSecret $inputData.clientSecret `
    -ResultPath $inputData.resultPath `
    -ServiceTokens $inputData.serviceTokens