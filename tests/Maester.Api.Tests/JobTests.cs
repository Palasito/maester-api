using Maester.Api.Contracts;
using Maester.Api.Services;
using Microsoft.Extensions.Options;
using Xunit;

namespace Maester.Api.Tests;

public sealed class JobTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "maester-tests-" + Guid.NewGuid().ToString("N"));
    private readonly TestClock clock = new();

    private JobStore Create(int concurrency = 1) => new(Options.Create(new MaesterOptions { DatabasePath = Path.Combine(directory, "jobs.db"), MaxConcurrentJobs = concurrency, RetentionSeconds = 60 }), clock);

    [Fact]
    public void RepeatedPollsRetainResultUntilTtl()
    {
        var store = Create();
        var job = store.TryCreate(new CreateMaesterRunRequest().Normalize(), default)!;
        Assert.True(store.Finish(job.JobId, "{\"totalCount\":0}", null));
        Assert.Equal("completed", store.Get(job.JobId, default)?.Status);
        Assert.Equal(0, store.Get(job.JobId, default)?.Result?.GetProperty("totalCount").GetInt32());
        clock.Advance(TimeSpan.FromSeconds(61));
        Assert.Null(store.Get(job.JobId, default));
    }

    [Fact]
    public async Task AdmissionIsAtomicUnderConcurrentRequests()
    {
        var store = Create();
        var attempts = await Task.WhenAll(Enumerable.Range(0, 10).Select(_ => Task.Run(() => store.TryCreate(new CreateMaesterRunRequest().Normalize(), default))));
        Assert.Single(attempts.OfType<MaesterRunAcceptedResponse>());
    }

    [Fact]
    public void LateCompletionCannotOverwriteTerminalFailure()
    {
        var store = Create();
        var job = store.TryCreate(new CreateMaesterRunRequest().Normalize(), default)!;
        Assert.True(store.Finish(job.JobId, null, "Scan timed out."));
        Assert.False(store.Finish(job.JobId, "{}", null));
        Assert.Equal("failed", store.Get(job.JobId, default)?.Status);
        Assert.Equal(1, store.GetStatistics().Failed);
    }

    [Fact]
    public void CancellationBeforeAdmissionDoesNotReserveCapacity()
    {
        var store = Create();
        Assert.Throws<OperationCanceledException>(() => store.TryCreate(new CreateMaesterRunRequest().Normalize(), new CancellationToken(true)));
        Assert.Equal(0, store.GetStatistics().Active);
    }

    [Fact]
    public void RestartMarksInterruptedJobsFailed()
    {
        var store = Create();
        var job = store.TryCreate(new CreateMaesterRunRequest().Normalize(), default)!;
        var restarted = Create();
        Assert.Equal("failed", restarted.Get(job.JobId, default)?.Status);
    }

    public void Dispose() => Directory.Delete(directory, true);

    private sealed class TestClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan amount) => now += amount;
    }
}