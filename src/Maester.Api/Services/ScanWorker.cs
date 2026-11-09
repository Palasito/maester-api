using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

public sealed class ScanWorker(RunCoordinator coordinator, IJobStore store, IScanRunner runner, IOptions<MaesterOptions> options,
    TimeProvider clock, ILogger<ScanWorker> logger) : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken) => Task.WhenAll(
        Enumerable.Range(0, options.Value.MaxConcurrentJobs).Select(_ => ConsumeAsync(stoppingToken)));

    private async Task ConsumeAsync(CancellationToken stoppingToken)
    {
        try
        {
            await foreach (var work in coordinator.Reader.ReadAllAsync(stoppingToken))
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(options.Value.TimeoutSeconds), clock);
                using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken, timeout.Token);
                try
                {
                    var result = await runner.RunAsync(work, lifetime.Token);
                    lifetime.Token.ThrowIfCancellationRequested();
                    store.Finish(work.JobId, result, null);
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
                {
                    store.Finish(work.JobId, null, stoppingToken.IsCancellationRequested ? "Scan interrupted by backend shutdown." : "Scan timed out.");
                }
                catch (Exception exception)
                {
                    logger.LogWarning("Scan worker failed ({ExceptionType}).", exception.GetType().Name);
                    store.Finish(work.JobId, null, "Maester worker failed. Check service permissions and module compatibility.");
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        coordinator.StopAccepting();
        await base.StopAsync(cancellationToken);
        while (coordinator.Reader.TryRead(out var pending))
            store.Finish(pending.JobId, null, "Scan interrupted by backend shutdown.");
    }
}