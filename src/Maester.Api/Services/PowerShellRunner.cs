using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

public interface IScanRunner
{
    Task<string> RunAsync(RunWorkItem work, CancellationToken cancellationToken);
}

public sealed class PowerShellRunner(IOptions<MaesterOptions> settings, IServiceTokenProvider tokenProvider, IWebHostEnvironment environment, IWorkerRegistry workers) : IScanRunner
{
    public async Task<string> RunAsync(RunWorkItem work, CancellationToken cancellationToken)
    {
        var options = settings.Value;
        var tokens = await tokenProvider.AcquireAsync(work, cancellationToken);
        var directory = Path.Combine(Path.GetTempPath(), "maester-" + Guid.NewGuid().ToString("N"));
        if (OperatingSystem.IsLinux())
            Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        else Directory.CreateDirectory(directory);
        using var outputLimit = new CancellationTokenSource();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, outputLimit.Token);
        var resultPath = Path.Combine(directory, "outcome.json");
        var startInfo = new ProcessStartInfo(options.PowerShellExecutable)
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            CreateNoWindow = true, WorkingDirectory = directory
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", Path.GetFullPath(options.WorkerScript, environment.ContentRootPath) })
            startInfo.ArgumentList.Add(argument);
        startInfo.Environment["TMPDIR"] = directory;
        startInfo.Environment["TMP"] = directory;
        startInfo.Environment["TEMP"] = directory;
        startInfo.Environment.Remove("MAESTER_API_KEY");
        using var process = new Process { StartInfo = startInfo };
        Task stdout = Task.CompletedTask;
        Task stderr = Task.CompletedTask;
        var started = false;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            started = process.Start();
            if (!started) throw new InvalidOperationException("Unable to start PowerShell worker.");
            workers.Add(process);
            stdout = DrainAsync(process.StandardOutput, outputLimit);
            stderr = DrainAsync(process.StandardError, outputLimit);
            var input = JsonSerializer.Serialize(new
            {
                graphToken = work.Credentials.GraphToken, clientId = work.Credentials.ClientId, clientSecret = work.Credentials.ClientSecret,
                configuration = work.Configuration, testsPath = Path.GetFullPath(options.TestsPath), resultPath, serviceTokens = tokens
            });
            await process.StandardInput.WriteAsync(input.AsMemory(), lifetime.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(lifetime.Token);
            await Task.WhenAll(stdout, stderr);
            if (outputLimit.IsCancellationRequested) throw new InvalidOperationException("Worker output exceeded the limit.");
            if (process.ExitCode != 0 || !File.Exists(resultPath)) throw new InvalidOperationException("PowerShell worker did not produce a result.");
            if (new FileInfo(resultPath).Length > options.MaxResultBytes) throw new InvalidOperationException("Worker result exceeded the limit.");
            await using var stream = File.OpenRead(resultPath);
            using var outcome = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            if (outcome.RootElement.GetProperty("status").GetString() != "completed")
                throw new InvalidOperationException("Maester scan failed. Check service permissions and module compatibility.");
            var result = outcome.RootElement.GetProperty("result");
            if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("tests", out var tests) || tests.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException("Worker result is invalid.");
            var json = result.GetRawText();
            foreach (var secret in new[] { work.Credentials.GraphToken, work.Credentials.ClientSecret }.Concat(tokens?.Values ?? []))
            {
                if (!string.IsNullOrEmpty(secret)) json = json.Replace(JsonEncodedText.Encode(secret).ToString(), "[redacted]", StringComparison.Ordinal);
            }
            return json;
        }
        finally
        {
            if (started)
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync(CancellationToken.None);
                await Task.WhenAll(stdout, stderr);
                workers.Remove(process);
            }
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task DrainAsync(StreamReader reader, CancellationTokenSource limit)
    {
        var buffer = new char[4096];
        var count = 0L;
        int read;
        while ((read = await reader.ReadAsync(buffer)) > 0)
        {
            count += read;
            if (count > 1024 * 1024) await limit.CancelAsync();
        }
    }
}