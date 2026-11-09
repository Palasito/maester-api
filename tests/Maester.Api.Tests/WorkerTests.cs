using Maester.Api.Contracts;
using Maester.Api.Services;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Options;
using Xunit;

namespace Maester.Api.Tests;

public sealed class WorkerTests
{
    [Fact]
    public async Task WorkerReadsSecretsFromStdinAndReturnsStructuredResult()
    {
        var runner = Create("success.ps1");
        var result = await runner.RunAsync(Work(), default);
        Assert.Contains("[redacted]", result);
        Assert.DoesNotContain("private-test-token", result);
    }

    [Theory]
    [InlineData("failure.ps1")]
    [InlineData("malformed.ps1")]
    public async Task RejectsMissingOrInvalidResult(string script)
    {
        await Assert.ThrowsAnyAsync<Exception>(() => Create(script).RunAsync(Work(), default));
    }

    [Fact]
    public async Task CancellationTerminatesWorker()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Create("hang.ps1").RunAsync(Work(), cancellation.Token));
    }

    private static RunWorkItem Work() => new("test", new CreateMaesterRunRequest().Normalize(), new RunCredentials("private-test-token", null, null));
    private static PowerShellRunner Create(string script) => new(Options.Create(new MaesterOptions
    {
        WorkerScript = Path.Combine(AppContext.BaseDirectory, "Fixtures", script)
    }), new NoTokens(), new TestEnvironment(), new WorkerRegistry());

    private sealed class NoTokens : IServiceTokenProvider
    {
        public Task<IReadOnlyDictionary<string, string?>?> AcquireAsync(RunWorkItem work, CancellationToken cancellationToken) => Task.FromResult<IReadOnlyDictionary<string, string?>?>(null);
    }

    private sealed class TestEnvironment : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "Tests";
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
        public string WebRootPath { get; set; } = ".";
        public string EnvironmentName { get; set; } = "Testing";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}