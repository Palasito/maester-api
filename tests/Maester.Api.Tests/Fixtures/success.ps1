$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ([Environment]::GetCommandLineArgs() -contains $request.graphToken) { exit 1 }
$outcome = @{ status = 'completed'; result = @{ tests = @(); totalCount = 0; detail = $request.graphToken } }
[IO.File]::WriteAllText($request.resultPath, ($outcome | ConvertTo-Json -Depth 10))