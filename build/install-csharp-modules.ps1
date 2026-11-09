$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$modules = Get-Content (Join-Path $PSScriptRoot 'modules.json') -Raw | ConvertFrom-Json -AsHashtable
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
foreach ($module in $modules.GetEnumerator()) {
    Install-Module -Name $module.Key -RequiredVersion $module.Value -Scope AllUsers -Force -AllowClobber -Repository PSGallery
}
Get-Module -ListAvailable Pester | Where-Object { $_.Version -ne [version]$modules['Pester'] } |
    ForEach-Object { Remove-Item $_.ModuleBase -Recurse -Force }
Import-Module Pester -RequiredVersion $modules['Pester'] -ErrorAction Stop
foreach ($module in $modules.GetEnumerator()) {
    Import-Module -Name $module.Key -RequiredVersion $module.Value -ErrorAction Stop
}
$revision = '7413c42d3fcc724dfea94d2726e690ddd364d914'
$archive = Join-Path ([IO.Path]::GetTempPath()) 'maester-tests.zip'
$unpack = Join-Path ([IO.Path]::GetTempPath()) 'maester-tests-source'
Invoke-WebRequest -Uri "https://codeload.github.com/maester365/maester/zip/$revision" -OutFile $archive
Expand-Archive $archive $unpack -Force
$source = Join-Path $unpack "maester-$revision/tests"
$destination = '/app/maester-tests'
$null = New-Item -ItemType Directory -Force $destination
Copy-Item "$source/*" $destination -Recurse -Force
foreach ($name in @{ 'maester' = 'Maester'; 'eidsca' = 'EIDSCA'; 'xspm' = 'XSPM' }.GetEnumerator()) {
    $current = Join-Path $destination $name.Key
    if (Test-Path $current) { Rename-Item $current $name.Value }
}
if (-not (Test-Path (Join-Path $destination 'maester-config.json'))) { throw 'Baked test inventory is missing.' }
$runtimeInfo = @{} + $modules
$runtimeInfo['PowerShell'] = $PSVersionTable.PSVersion.ToString()
$runtimeInfo['TestRevision'] = $revision
$runtimeInfo | ConvertTo-Json | Set-Content (Join-Path $destination 'runtime-info.json')
Remove-Item $archive, $unpack -Force -Recurse