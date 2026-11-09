$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
[IO.File]::WriteAllText($request.resultPath, 'not json')