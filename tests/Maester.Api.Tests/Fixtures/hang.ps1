$null = [Console]::In.ReadToEnd()
[Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null